    ________        _________               ____________
    ___  __ \______ ______  /______________ ___  /___  /_____ ________
    __  /_/ /_  __ \_  __  / __  ___/_  __ \__  / __  / _  _ \__  ___/
    _  ____/ / /_/ // /_/ /  _  /    / /_/ /_  /  _  /  /  __/_  /
    /_/      \____/ \__,_/   /_/     \____/ /_/   /_/   \___/ /_/

# What

Podroller delivers prerolled audio files without caching the concatenated
files on disk.

It can also inject a session UUID to make _206 Partial Content_ requests easier
to de-duplicate.

# Requirements

Podroller currently expects to get transcoded preroll and doesn't have any
sense of impression tracking. At SCPR, this preroll is delivered by
[Adhost](https://github.com/scpr/Adhost).

* node & NPM
* grunt

# Development

To run podroller on your machine, run grunt to compile coffee script to javascript (to incorporate any changes) and then run:
`NODE_ENV="development" node app.js`

^ This will look for a config script `development.json` in the `config` directory. If that does not exist
then create one like this:

```
{
    "debug": true,
    "redirect_url": "http://127.0.0.1:3000",
    "audio_dir": "./audio",
    "port": 3000,
    "prefixes": {
      "/podcasts": {
        "preroll_key": "podcast"
      },
      "/audio": {
        "preroll_key": "podcast"
      }
    },
}
```

Make sure there is an `audio` directory in the root dir of this project, stick an mp3 file in it (`test.mp3`) and once the server is running, you can access the file from:
`http://localhost:3000/audio/podcasts/test.mp3`

# Who

Podroller is used by [Southern California Public Radio](http://www.scpr.org).
Development was started in 2012 by [Eric Richardson](http://ewr.is).
