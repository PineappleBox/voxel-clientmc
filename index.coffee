ndarray = require 'ndarray'
websocket_stream = require 'websocket-stream'
minecraft_protocol = require 'minecraft-protocol'
ever = require 'ever'
webworkify = require 'webworkify'
tellraw2dom = require 'tellraw2dom'
{popCount} = require 'bit-twiddle'

module.exports = (game, opts) ->
  return new ClientMC(game, opts)

module.exports.pluginInfo =
  loadAfter: ['voxel-land', 'voxel-player', 'voxel-registry', 'voxel-console']


decodePacket = (data) -> # based on https://github.com/deathcap/wsmc/tree/master/examples/mcwebchat
  if !(data instanceof Uint8Array)
    return undefined

  # convert typed array to NodeJS buffer for minecraft-protocol's API
  # TODO: is this conversion fast? backed by ArrayBuffer in Browserify 3, see https://npmjs.org/package/native-buffer-browserify
  #  but is this the right way to "convert" from an ArrayBuffer to a Buffer, without copying?
  data._isBuffer = true
  buffer = new Buffer(data)


  state = 'play'
  isServer = false
  packetsToParse = {packet: true}
  result = minecraft_protocol.protocol.parsePacket(buffer, state, isServer, packetsToParse)
  if !result || result.error
    @log('protocol parse error: ' + JSON.stringify(result.error))
    return undefined

  payload = result.results
  id = result.results.id
  name = minecraft_protocol.protocol.packetNames[minecraft_protocol.protocol.states.PLAY].toClient[id]

  return {name:name, id:id, payload:payload}


class ClientMC
  constructor: (@game, @opts) ->
    @registry = @game.plugins?.get('voxel-registry') ? throw new Error('voxel-clientmc requires voxel-registry plugin')
    @console = @game.plugins?.get('voxel-console') # optional

    @opts.url ?= "ws://#{document.location.hostname}:1234"

    # map http://minecraft.gamepedia.com/Data_values#Block_IDs to our block names
    @opts.mcBlocks ?=
      0: 'air'
      1: 'stone'
      2: 'grass'
      3: 'dirt'
      4: 'cobblestone'
      5: 'plankOak'

      7: 'obsidian'   # bedrock

      16: 'oreCoal'

      17: 'logOak'
      18: 'leavesOak'

      161: 'leavesOak'
      162: 'logOak'

      default: 'brick'
    
    @mcPlayerHeight = 1.74 # from https://github.com/superjoe30/mineflayer/blob/4daa1f8a1f4282755b723df4bb748f6602784744/lib/plugins/physics.js#L23 - tested with a binary search

    @enable()

  enable: () ->
    @log 'voxel-clientmc initializing...'

    @game.plugins?.disable('voxel-land')    # also provides chunks, use ours instead
    #@game.plugins?.get('voxel-player').homePosition = [-248, 77, -198] # can't do this TODO
    #@game.plugins?.get('voxel-player').moveTo -251, 81, -309
    @game.plugins?.enable('voxel-fly')

    @ws = websocket_stream(@opts.url, {type: Uint8Array})

    @game.voxels.on 'missingChunk', @missingChunk.bind(this)

    @voxelChunks = {}

    # WebSocket to server proxy (wsmc)
    @ws.on 'error', (err) =>
      @log 'WebSocket error', err
      @game.plugins?.disable('voxel-clientmc')
    @ws.on 'end', () =>
      @log 'WebSocket end'
      @game.plugins?.disable('voxel-clientmc')

    @ws.on 'data', (data) =>
      packet = decodePacket(data)
      if not packet?
        return

      @handlePacket packet.name, packet.payload

    @console?.widget?.on 'input', @onConsoleInput = (text) =>
      @sendChat(text)

    # chunk decompression
    @zlib_worker = webworkify(require('./zlib_worker.js'))
    ever(@zlib_worker).on 'message', @onDecompressed.bind(@)
    @packetPayloadsPending = {}
    @packetPayloadsNextID = 0

    maxId = 255 # TODO: 4096?

    # array MC block ID -> our block ID
    # TODO: also support .metadata (MC block ID = 12-bits, meta = 4-bits, total 16-bits -> ours 16 bit)
    @translateBlockIDs = new @game.arrayType(maxId)
    for mcID in [0...@translateBlockIDs.length]
      @translateBlockIDs[mcID] = @registry.getBlockIndex(@opts.mcBlocks.default)
    for mcID, ourBlockName of @opts.mcBlocks
      ourBlockID = @registry.getBlockIndex(ourBlockName)
      throw new Error("voxel-clientmc unrecognized block name: #{ourBlockName} for MC #{mcID}") if not ourBlockID?
      @translateBlockIDs[mcID] = ourBlockID

    # for chunk conversion - see voxel/chunker.js
    @chunkBits = Math.log(@game.chunkSize) / Math.log(2) # must be power of two
    @chunkBits |= 0
    @chunkMask = (1 << @chunkBits) - 1

  disable: () ->
    @log 'voxel-clientmc disabling'
    @game.voxels.removeListener 'missingChunk', @missingChunk
    @game.plugins?.get('voxel-console').widget.removeListener 'input', @onConsoleInput
    @ws.end()
    @clearPositionUpdateTimer?()

  # call the browser console.log() function with arguments as an array
  nativeConsoleLog: (args) ->
    Function.prototype.bind.call(console.log, console).apply(console, args) # see http://stackoverflow.com/questions/5538972

  # log to browser and to user console if available
  log: (msg, rest...) ->
    @nativeConsoleLog ['[voxel-clientmc] ' + msg].concat(rest)  # as separate parameters to allow object expansion
    @console?.log msg + ' ' + rest.join ' '

  handlePacket: (name, payload) ->
    if name == 'map_chunk_bulk'
      @log 'payload.compressedChunkData ',payload.compressedChunkData.length,payload.compressedChunkData

      #require('zlib').inflate payload.compressedChunkData, (err, decompressed) =>
      #  @log 'NON-WORKER decomp=',err+'',decompressed

      id = @packetPayloadsNextID
      @packetPayloadsPending[id] = payload # save for continued processing in onDecompressed
      @packetPayloadsNextID += 1
      # send the ArrayBuffer as a transferrable, along with any possible offsets/length within the data view
      compressed = payload.compressedChunkData.buffer
      byteLength = payload.compressedChunkData.byteLength
      byteOffset = payload.compressedChunkData.byteOffset
      @log 'sending compressedBuffer ',byteLength
      @zlib_worker.postMessage {id, compressed, byteOffset, byteLength}, [compressed]
   
    else if name == 'spawn_position'
      # move to spawn TODO: this might only reset the compass 
      @log 'Spawn at ',payload
      @game.plugins?.get('voxel-player').moveTo payload.x, payload.y, payload.z
      #@game.plugins?.get('voxel-player').homePosition = [-248, 77, -198] # can't do this TODO
      
      @setupPositionUpdates()  # TODO: now or when?
    
    else if name == 'block_change'
      @log 'block_change',payload
      blockID = @translateBlockIDs[payload.type] #  TODO: .metadata
      @game.setBlock [payload.x, payload.y, payload.z], blockID

    else if name == 'position'
      # TODO, yaw, pitch. to convert see http://wiki.vg/Protocol#Player_Position_And_Look
      @log 'player pos and look', payload
      ourY= payload.y - 1.62 # empirical  TODO: not playerHeight?
      @game.plugins?.get('voxel-player').moveTo payload.x, ourY, payload.z

      # the "apology"
      @sendPacket 'position', payload

    else if name == 'kick_disconnect'
      window.alert "Disconnected from server: #{payload.reason}"  # TODO: console, also for chat
    else if name == 'chat'
      # log formatted message
      @game.plugins?.get('voxel-console').logNode tellraw2dom(payload.message)

  sendChat: (text) ->
    @sendPacket 'chat', {message: text}

  # setup timer to send player position updates to the server
  setupPositionUpdates: () ->
    # MC requires every 50 ms (server = 20 ticks/second)
    @clearPositionUpdateTimer = @game.setInterval @sendPositionUpdate.bind(@), 50

  sendPositionUpdate: () ->
    pos = @game.plugins?.get('voxel-player').yaw.position
    return if not pos?

    x = pos.x
    y = pos.y + 1
    z = pos.z

    stance = y + @mcPlayerHeight
    onGround = true

    @sendPacket 'position', {x, y, z, stance, onGround}

  sendPacket: (name, params) ->
    state = 'play'
    data = minecraft_protocol.protocol.createPacketBuffer name, state, params
    @ws.write(data)  # TODO: handle error

  onDecompressed: (ev) ->
    @log 'onDecompressed',ev

    id = ev.data.id
    payload = @packetPayloadsPending[id]
    delete @packetPayloadsPending[id]

    if ev.data.err
      @log 'received decompression error',ev.data.err,' for ',ev.data.id
      return

    inflated = new Buffer(new Uint8Array(ev.data.decompressed))  # new Buffer() for .slice method below. TODO: replace with typed array alternative
    @log '  decomp', id, inflated.length

    # unpack chunk data
    # based on https://github.com/superjoe30/mineflayer/blob/cc3eae10f622da24c9051268e9fc8ec3fe01ed7e/lib/plugins/blocks.js#L195
    # and http://wiki.vg/SMP_Map_Format#Data
    offset = meta = size = 0
    for meta, i in payload.meta
      size = (8192 + (if payload.skyLightSent then 2048 else 0)) *
        popCount(meta.bitMap) +
        2048 * popCount(meta.addBitMap) + 256
      @addColumn(
        x: meta.x
        z: meta.z
        bitMap: meta.bitMap
        addBitMap: meta.addBitMap
        skyLightSent: payload.skyLightSent
        groundUp: true
        data: inflated.slice(offset, offset + size)
      )
      offset += size

    if offset != inflated.length
      @log "incomplete chunk decode: #{offset} != #{inflated.length}"


  # convert MC chunk format to ours, caching to be ready for missingChunk()
  addColumn: (args) ->
    chunkX = args.x
    chunkZ = args.z

    column = []

    offset = 0
    size = 4096
    for chunkY in [0...16]
      if args.bitMap & (1 << chunkY)
        miniChunk = args.data.slice(offset, offset + size)
        offset += size

        # convert MC's chunks to voxel-engine's
        # TODO: speed this up somehow
        for dy in [0...16]
          y = chunkY*16 + dy
          for dz in [0...16]
            z = chunkZ*16 + dz
            for dx in [0...16]
              x = chunkX*16 + dx

              # MC uses XZY ordering, 16x16x16 mini-chunks
              mcBlockID = miniChunk[dx + dz*16 + dy*16*16]

              # voxel-engine uses XYZ, (by default) 32x32x32
              # calculate chunk coordinates
              vchunkKey = (x >> @chunkBits) + '|' + (y >> @chunkBits) + '|' + (z >> @chunkBits)
              @voxelChunks[vchunkKey] ?= new @game.arrayType(@game.chunkSize * @game.chunkSize * @game.chunkSize)

              ourBlockID = @translateBlockIDs[mcBlockID]

              # our block offsets within the chunk, scaled
              vindex = (x & @chunkMask) + ((y & @chunkMask) << @chunkBits) + ((z & @chunkMask) << @chunkBits * 2)
              @voxelChunks[vchunkKey][vindex] = ourBlockID

      else
        # entirely air

    # TODO: metadata,light,sky,add,biome
    
  missingChunk: (pos) ->
    voxels = @voxelChunks[pos.join('|')]
    return if not voxels?

    shape = [@game.chunkSize, @game.chunkSize, @game.chunkSize]

    if not @game.voxels.voxelIndex  # ndarray voxel removes this in https://github.com/maxogden/voxel/pull/18 TODO: better detection?
      chunk = ndarray(voxels, shape)
      chunk.position = pos
    else
      # pre-ndarray format TODO: support this too in ndarray voxel?
      chunk = {
        position: pos
        dims: shape
        voxels: voxels
      }

    @game.showChunk(chunk)

