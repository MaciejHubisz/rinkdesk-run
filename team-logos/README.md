# Team logos

Drop team logo image files here (PNG/JPG, small, e.g. 200x200 px). There is no
upload in the app: this folder is bind-mounted into the running desk, so the
logo files physically live on the machine that runs `./start.sh`.

How to connect a logo to a team:

1. Put the file here, e.g. `orly.png`.
2. Open the team in the app and set **Logo file** to the exact file name, e.g.
   `orly.png`.

When the desk is running, the file is served under `/logos/orly.png` and the
logo is drawn in the standings table and on the printed protocol. Files without
a matching team are ignored.

Copy the same images to this folder on every machine that runs the desk.
