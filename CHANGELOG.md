# Changelog

## [0.1.1](https://github.com/wadackel/diffreel.nvim/compare/v0.1.0...v0.1.1) (2026-09-22)


### Bug Fixes

* complete paths that contain [, % or # as literal arguments ([#34](https://github.com/wadackel/diffreel.nvim/issues/34)) ([61220c6](https://github.com/wadackel/diffreel.nvim/commit/61220c68ecad39f733046ac39ac0fa61084646af))
* correct review headers, command errors and PR cache completion ([#23](https://github.com/wadackel/diffreel.nvim/issues/23)) ([1226345](https://github.com/wadackel/diffreel.nvim/commit/1226345e3eae8e404ceed5de3c5ecc618949282d))
* report inaccessible repository paths without a Lua traceback ([#31](https://github.com/wadackel/diffreel.nvim/issues/31)) ([2854e5f](https://github.com/wadackel/diffreel.nvim/commit/2854e5fdc027c9ac6a22bcaaf731671e095999d3))
* resolve :/&lt;text&gt; revision searches ([#33](https://github.com/wadackel/diffreel.nvim/issues/33)) ([8652022](https://github.com/wadackel/diffreel.nvim/commit/86520227699e2d060fcad170c96e74e26b1d6bda))
* return focus to the explorer when toggling it back ([#25](https://github.com/wadackel/diffreel.nvim/issues/25)) ([5c9c8e9](https://github.com/wadackel/diffreel.nvim/commit/5c9c8e9a1c78b921c5b52507df7794244795b1a4))
* show why the daemon stopped instead of "Backend is closed" ([#32](https://github.com/wadackel/diffreel.nvim/issues/32)) ([aa4e56b](https://github.com/wadackel/diffreel.nvim/commit/aa4e56b623789fff0799e125e872fbd0c9a938f2))
* skip unsupported inline when cycling layouts ([#36](https://github.com/wadackel/diffreel.nvim/issues/36)) ([ad27283](https://github.com/wadackel/diffreel.nvim/commit/ad27283d060ec0031a0fcb53795682ca8360c320))
* treat only the owner execute bit as an executable worktree file ([#35](https://github.com/wadackel/diffreel.nvim/issues/35)) ([cb81a6a](https://github.com/wadackel/diffreel.nvim/commit/cb81a6ac48445a3679431a76a4ac17829c5588d8))

## 0.1.0 (2026-09-18)


### Features

* add configurable explorer status icons ([#9](https://github.com/wadackel/diffreel.nvim/issues/9)) ([f6d055d](https://github.com/wadackel/diffreel.nvim/commit/f6d055d3611e067940fc8e2a9de301d52405f553))
* add versioned plugin releases ([#5](https://github.com/wadackel/diffreel.nvim/issues/5)) ([09d2b09](https://github.com/wadackel/diffreel.nvim/commit/09d2b099f0af7885287c824fc8fd95c3a718be79))
* animate the loading symbol while a review waits ([#13](https://github.com/wadackel/diffreel.nvim/issues/13)) ([8e8d077](https://github.com/wadackel/diffreel.nvim/commit/8e8d07745beef64dee646e5420841a86065e8672))
* expand clipped explorer names at the cursor ([#10](https://github.com/wadackel/diffreel.nvim/issues/10)) ([7875779](https://github.com/wadackel/diffreel.nvim/commit/78757790e63958cea89800228a60765f07e1d473))
* pin the explorer's waiting rows to the bottom of the pane ([#14](https://github.com/wadackel/diffreel.nvim/issues/14)) ([d08492d](https://github.com/wadackel/diffreel.nvim/commit/d08492d41a31dd92b33cd03b50b49edf69f8431d))
* publish diffreel.nvim ([6072f3e](https://github.com/wadackel/diffreel.nvim/commit/6072f3e6ff5d52a429dadd7d329968ac07a5d627))
* refine review presentation ([#3](https://github.com/wadackel/diffreel.nvim/issues/3)) ([5f18320](https://github.com/wadackel/diffreel.nvim/commit/5f18320ae995a168431689e1e7b2ad93cd6eab55))
* resize explorer and preserve diff pane proportions ([#4](https://github.com/wadackel/diffreel.nvim/issues/4)) ([95b7ae4](https://github.com/wadackel/diffreel.nvim/commit/95b7ae4bbf245cb635041cb02fdb07e2b16c0d46))
* show review activity at the right end of the top-right winbar ([#18](https://github.com/wadackel/diffreel.nvim/issues/18)) ([5c72f59](https://github.com/wadackel/diffreel.nvim/commit/5c72f59a9996ee45377fa7e9e6ab56214bc441e8))
* unify review UI icons and labels ([#12](https://github.com/wadackel/diffreel.nvim/issues/12)) ([576d2c5](https://github.com/wadackel/diffreel.nvim/commit/576d2c5c8db4bc29a6b8ece6246619a27bd2e730)), closes [#9](https://github.com/wadackel/diffreel.nvim/issues/9)


### Bug Fixes

* align diff panes when switching files ([#17](https://github.com/wadackel/diffreel.nvim/issues/17)) ([1d26d82](https://github.com/wadackel/diffreel.nvim/commit/1d26d8243eab9e329fd00fa139419fde18c119be))
* keep file selection responsive in large repositories ([#15](https://github.com/wadackel/diffreel.nvim/issues/15)) ([93ba163](https://github.com/wadackel/diffreel.nvim/commit/93ba16371f34fefda46a157c26ee86ecebeaf7e3))
* preserve configured diff filler characters ([#7](https://github.com/wadackel/diffreel.nvim/issues/7)) ([1231cf5](https://github.com/wadackel/diffreel.nvim/commit/1231cf51b0c65d168dd4fdcc66cc754a37e7c73e))

## Changelog
