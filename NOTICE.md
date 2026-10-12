# Third-party notices

Wijeti is licensed under the GNU General Public License v3.0 (see `LICENSE`). It bundles and builds on the following components, each
under its own license. The complete corresponding source for everything shipped in the app is in this
repository (`server/` is the unmodified engine source).

| Component | Use | License |
| --- | --- | --- |
| [Übersicht](https://github.com/felixhageloh/Uebersicht) widget engine (`server/`) by Felix Hageloh | Widget runtime, run as a separate process | GPL-3.0 (see `server/package.json`) |
| [Node.js](https://nodejs.org) (`node-arm64` / `node-x64`) | Runs the widget engine | MIT, Copyright Node.js contributors. Full text: <https://github.com/nodejs/node/blob/main/LICENSE> |
| [Sparkle](https://sparkle-project.org) | Automatic updates | MIT, Copyright (c) 2006-2013 Andy Matuschak and others |
| Bundled widgets (`Resources/presets/`) | Example widgets | Per widget; `liquid-glass-calendar.widget/LICENSE` applies to that widget |
| npm dependencies of the widget engine (`server/node_modules`) | Engine dependencies | Each package's own license, included in its folder |

The MIT license requires this notice to accompany copies of the software:

> Permission is hereby granted, free of charge, to any person obtaining a copy of this software and
> associated documentation files (the "Software"), to deal in the Software without restriction,
> including without limitation the rights to use, copy, modify, merge, publish, distribute,
> sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions: The above copyright notice and this
> permission notice shall be included in all copies or substantial portions of the Software. THE
> SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED.
