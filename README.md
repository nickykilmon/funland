# FunLand

3D multiplayer funbrick building game made in Godot 4.7.

- `scripts/` – the game (Godot project in this folder)
- `server/` – Node website: serves the web build in `server/public` and relays multiplayer at `/ws`

## Updating the website
1. Export: `Godot --headless --path . --export-release "Web" server/public/index.html`
2. Commit and push to `main` – Render redeploys automatically.

## Running the server locally
`cd server && npm install && npm start` then open http://localhost:3123
