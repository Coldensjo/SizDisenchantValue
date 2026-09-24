# DisenchantValue

World of Warcraft addon (Siz DisenchantValue). Addon folder name is `DisenchantValue`; the GitHub repo is `Coldensjo/SizDisenchantValue`.

- CurseForge: https://www.curseforge.com/wow/addons/siz-disenchantvalue (project ID 1709282)
- GitHub: https://github.com/Coldensjo/SizDisenchantValue

## Releasing (CurseForge automatic packaging)

CurseForge builds and uploads the zip itself through a GitHub webhook
(`https://www.curseforge.com/api/projects/1709282/package?token=...`). Nothing is built locally.

- Every push must be tagged, so each pushed change ships as a Release instead of an untagged Alpha:
	- Find the latest tag with `git tag --sort=-v:refname | head -1` and bump it: patch (`1.0.1`) for fixes, minor (`1.1.0`) for new features. If no tags exist yet, ask the user for the starting version.
	- Commit, then tag and push branch and tag together: `git tag 1.0.1 && git push origin main 1.0.1`.
	- Only use a tag containing `alpha` or `beta` when the user asks for a test build.
	- Tag containing `alpha` → Alpha, containing `beta` → Beta, anything else → Release. A push with no tag becomes an Alpha.
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
