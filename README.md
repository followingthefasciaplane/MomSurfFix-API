# momsurffix2 api
this fork creates an inter-plugin API for third party plugins to take advantage of the deep engine hooks and precise movement data that this plugin provides. it detours tryplayermove so it has movement authority, and by exposing that, we can have server-accurate data.  
  
# note (dont use this off LAN)
untested on public servers or with multiple clients. performance might be an issue. mainly intended for LAN use right now. this stuff is a bit over my head, i just created this because because i needed this data for some TAS stuff i'm doing. a ton of stuff might actually be broken, i ripped out the profiler beacuse it confused me. you may need to make some changes and profile it again, because i cannot imagine the performance impact is small, and it is possible i have just broken stuff too.  
  
# docs
- documentation for the API can be found [here](addons/sourcemod/scripting/include/momsurffix2.inc)  
- original documentation for momsurffix2 can be found [here](https://github.com/GAMMACASE/MomSurfFix)
- an article about surf physics can be found [here](https://github.com/followingthefasciaplane/MomSurfFix-API/blob/master/surf-physics.md) if you want to learn what all of this means

# momsurffix2_apitest.sp
this is a plugin to test api functionality. chat commands will begin logging API forwards for a client:
- start: /sm_momsurf_test @me 1
- stop: /sm_momsurf_test @me 0
- logs are here: addons/sourcemod/logs/momsurffix2-api/PlayerName_SteamID.log
  
# credits
100% to gammacase and the momentum mod guys, all i did was add forwards and (maybe) break something.

# fun examples
1. [surf ramp boarding trainer (realtime feedback for boarding)](https://www.youtube.com/watch?v=CerAtEUGvwY)
2. [surf physics hud](https://www.youtube.com/watch?v=MPAS31U0mws)
