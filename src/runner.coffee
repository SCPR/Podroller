Podroller   = require "./podroller"
nconf       = require "nconf"

# -- do we have a config file to open? -- #

# get config from environment or command line
nconf.env().argv()

# add in config file
config_file = nconf.get("config") || nconf.get("CONFIG")
nconf.file file:config_file if config_file

nconf.defaults
    debug:              false
    port:               8000
    prefix:             ""

# -- launch our core -- #

process.title = "Podroller"

core = new Podroller nconf.get()
