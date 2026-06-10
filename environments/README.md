# Environments

Choose your environment and follow its setup guide before applying any module.

- **dev** — Docker Desktop on macOS (Apple Silicon) → [dev/setup.md](dev/setup.md)
- **prod** — Docker Engine on Ubuntu 24.04 LTS (EC2 t4g.micro / local VM) → [prod/setup.md](prod/setup.md)

`dev` uses bind mounts and relaxed restart policies for iteration speed.
`prod` uses named volumes, healthchecks, and enforced security defaults.
