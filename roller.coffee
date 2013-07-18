Podroller= require("./src/podroller/core")
nconf = require("nconf")

# -- do we have a config file to open? -- #

# get config from environment or command line
nconf.env().argv()

# add in config file
nconf.file( { file: nconf.get("config") || nconf.get("CONFIG") || "/etc/podroller.conf" } )

# -- launch our core -- #

DEBUG = nconf.get("debug")

console.debug = (messages...) ->
    if DEBUG
        console.log "DEBUG:", messages...


core = new Podroller nconf.get("podroller")
