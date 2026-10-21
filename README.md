# oracle-minecraft

Keeps requesting an Oracle Cloud Always Free Ampere A1 VM (2 OCPU, 12 GB, Santiago) until capacity
frees up, then boots it with `server/setup.sh`, which installs a Fabric Minecraft server with
Lithium, FerriteCore, Krypton, Spark, Chunky, EasyAuth and SkinRestorer (plus ScalableLux and C2ME once they have stable releases).

No secrets live in this repo. Oracle credentials are GitHub Actions secrets.
