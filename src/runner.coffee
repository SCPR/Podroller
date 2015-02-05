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
    max_zombie_life:    2 * 60 * 1000

# -- launch our core -- #

core = new Podroller nconf.get()
