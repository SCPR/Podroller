Stream      = require('stream').Stream
strtok      = require('strtok')
parseFrame  = require("./lib/parse").parseFrameHeader

module.exports = class MP3 extends Stream
    ID3V1_LENGTH            = 128
    ID3V2_HEADER_LENGTH     = 10
    MPEG_HEADER_LENGTH      = 4

    FIRST_BYTE = new strtok.BufferType(1)

    MPEG_HEADER             = new strtok.BufferType(MPEG_HEADER_LENGTH)
    REST_OF_ID3V2_HEADER    = new strtok.BufferType(ID3V2_HEADER_LENGTH - MPEG_HEADER_LENGTH)
    REST_OF_ID3V1           = new strtok.BufferType(ID3V1_LENGTH - MPEG_HEADER_LENGTH)



    constructor: (assumeOnTrack=false)->
        super
        @readable = @writable = true

        @setMaxListeners 0

        # set up status
        @frameSize  = -1
        @beginning  = true
        @gotFF      = false
        @byteTwo    = null

        @frameHeader = if assumeOnTrack then true else null

        @id3v2              = null
        @_parsingId3v2      = false
        @_finishingId3v2    = false
        @_id3v2_1           = null
        @_id3v2_2           = null

        strtok.parse @, (v,cb) =>
        strtok.parse @, (v, cb) =>
            # -- initial request -- #
            if v == undefined
                # we need to examine each byte until we get a FF
                return if assumeOnTrack then MPEG_HEADER else FIRST_BYTE

            # -- ID3v2 tag -- #
            if @_parsingId3v2
                # we'll already have @id3v2 started with versionMajor and 
                # our first byte in @_id3v2_1
                @id3v2.versionMinor = v[0]
                @id3v2.flags        = v[1]

                # calculate the length
                # from node-id3
                offset  = 2
                byte1   = v[offset]
                byte2   = v[offset + 1]
                byte3   = v[offset + 2]
                byte4   = v[offset + 3]

                @id3v2.length =
                   byte4   & 0x7f         |
                   ((byte3 & 0x7f) << 7)  |
                   ((byte2 & 0x7f) << 14) |
                   ((byte1 & 0x7f) << 21)

                @_parsingId3v2      = false
                @_finishingId3v2    = true
                @_id3v2_2           = v

                return new strtok.BufferType @id3v2.length

            if @_finishingId3v2
                # step 3 in the ID3v2 parse... 
                b = @buffer_concat(@_id3v2_1, @_id3v2_2, v)
                @emit 'id3v2', b

                @_finishingId3v2 = false

                return MPEG_HEADER


            # -- frame header -- #
            if @frameSize == -1 && @frameHeader
                # we're on-schedule now... we've had a valid frame.
                # buffer should be four bytes
                tag = v.toString 'ascii', 0, 3

                if tag == 'ID3'
                    # parse ID3 tag
                    console.log "got an ID3"
                    @_parsingId3v2  = true
                    @id3v2          = versionMajor: v[3]
                    @_id3v2_1       = v

                    return REST_OF_ID3V2_HEADER

                else if tag == 'TAG'
                    # parse ID3v2 tag
                    console.log "got a TAG"
                    process.exit(1)

                else
                    try
                        h = parseFrame(v)
                    catch e
                        # uh oh...  bad news
                        console.log "invalid header... ", v, tag, @frameHeader
                        @frameHeader = null
                        return FIRST_BYTE

                    @frameHeader = h
                    @emit "header", v, h
                    @frameSize = @frameHeader.frameSize

                    if @frameSize == 1
                        # problem...  just start over
                        console.log "Invalid frame header: ", h
                        return FIRST_BYTE
                    else
                        return new strtok.BufferType(@frameSize - MPEG_HEADER_LENGTH)

            # -- first header -- #
            if @gotFF and @byteTwo
                buf     = new Buffer(4)
                buf[0]  = 0xFF
                buf[1]  = @byteTwo
                buf[2]  = v[0]
                buf[3]  = v[1]

                try
                    h = parseFrame(buf)
                catch e
                    # invalid header...  chuck everything and try again
                    console.log "chucking invalid try at header: ", buf
                    @gotFF = false
                    @byteTwo = null
                    return FIRST_BYTE

                # valid header...  we're on schedule now
                @gotFF      = false
                @byteTwo    = null
                @beginning  = false

                @frameHeader = h
                @emit "header", buf, h
                @frameSize = @frameHeader.frameSize

                if @frameSize == 1
                    # problem...  just start over
                    console.log "Invalid frame header: ", h
                    return FIRST_BYTE
                else
                    console.log "On-tracking with frame of: ", @frameSize - MPEG_HEADER_LENGTH
                    return new strtok.BufferType(@frameSize - MPEG_HEADER_LENGTH);

            if @gotFF
                if v[0]>>4 >= 0xE
                    @byteTwo = v[0]

                    # need two more bytes
                    return new strtok.BufferType(2)
                else
                    @gotFF = false

            if @frameSize == -1 && !@gotFF
                if v[0] == 0xFF
                    # possible start of frame header. need next byte to know more
                    @gotFF = true
                    return FIRST_BYTE
                else
                    # keep looking
                    return FIRST_BYTE

            # -- data frame -- #
            @emit "frame", v

            @frameSize = -1
            return MPEG_HEADER



    write: (chunk) ->
        @emit "data", chunk
        true



    end: (chunk) ->
        @emit("data", chunk) if chunk
        @emit "end"
        true



    buffer_concat: (bufs) ->
        buffer = null
        length = 0
        index  = 0

        if !Array.isArray(bufs)
            bufs = Array.prototype.slice.call(arguments);

        for buf in bufs
            length += buf.length

        buffer = new Buffer length

        for buf in bufs
            buf.copy buffer, index, 0, buf.length
            index += buf.length

        buffer
