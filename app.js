nconf = require("nconf")
path  = require("path")
Podroller = require("./js/podroller")

nconf.file(path.resolve(__dirname,"config",(process.env.NODE_ENV||"production")+".json"))

new Podroller(nconf.get())