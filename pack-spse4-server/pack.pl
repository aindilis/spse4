name(spse4_server).
version('0.3.0').
title('SPSE4 server: HTTP + Pengines + broadcast fanout + per-mt ACL').
keywords([server, pengines, http, websocket, broadcast, frkcsa, spse4]).
author('Andrew Dougherty', 'adougher9@yahoo.com').
packager('FRKCSA', 'https://frdcsa.org').
maintainer('Andrew Dougherty', 'adougher9@yahoo.com').
home('https://github.com/aindilis/pack-spse4-server').
download('https://github.com/aindilis/pack-spse4-server/releases/*.zip').
requires(prolog >= '9.0.0').
requires(mt_store).
requires(spse4_core).
