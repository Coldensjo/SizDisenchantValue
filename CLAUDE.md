# DisenchantValue

World of Warcraft addon (Siz DisenchantValue). Addon folder name is `DisenchantValue`; the GitHub repo is `Coldensjo/SizDisenchantValue`.

- CurseForge: https://www.curseforge.com/wow/addons/siz-disenchantvalue (project ID 1709282)
- GitHub: https://github.com/Coldensjo/SizDisenchantValue

## Releasing (CurseForge automatic packaging)

CurseForge builds and uploads the zip itself through a GitHub webhook
(`https://www.curseforge.com/api/projects/1709282/package?token=...`). Nothing is built locally.

- A release is made by pushing a git tag: `git tag 0.2.0 && git push origin 0.2.0`.
	- Tag containing `alpha` → Alpha, containing `beta` → Beta, anything else → Release.
- `.pkgmeta` controls packaging:
	- `package-as: DisenchantValue` must stay equal to the `.toc` name, or the game will not load the addon (the repo name differs).
	- Add new non-addon files (docs, config) to its `ignore:` list so they stay out of the zip.
	- It is YAML: indent with spaces, not tabs.
- `DisenchantValue.toc`:
	- `## Version: @project-version@` is replaced with the tag by the packager; do not hard-code a version.
	- `## X-Curse-Project-ID: 1709282` links the addon to the CurseForge project.
	- The packager reads the game version from `## Interface:`. If an upload fails or shows the wrong game version, check that value first.
- New Lua/XML files must be listed in the `.toc` to be loaded.
- Never commit the CurseForge API token; it only belongs in the GitHub webhook settings.

## Code style

- Indent with tabs (tab size 4), except YAML (`.pkgmeta`).
