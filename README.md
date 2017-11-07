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

# Who

Podroller is used by [Southern California Public Radio](http://www.scpr.org).
Development was started in 2012 by [Eric Richardson](http://ewr.is).
