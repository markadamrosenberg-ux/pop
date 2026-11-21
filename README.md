# Bubble Pop (working title)

A relaxing 8×8 block-placement puzzle for mobile browsers. Drag pieces of bubbles onto the grid, complete rows or columns to pop them in a ripple of splashes, and clear the whole board for a waterfall and a new look.

## Run it

The whole game is one file, `index.html`, with no build step and no dependencies.

- **Quickest:** open `index.html` in a browser.
- **Local server (recommended, so phones on your Wi-Fi can reach it):**
  ```
  python3 -m http.server 8000
  ```
  Then open `http://localhost:8000` (or `http://<your-computer-ip>:8000` on your phone).
- **Hosting:** upload `index.html` to any static host (Replit static, Netlify, Vercel, S3). It needs no backend.

## Changing things

Everything tunable is in the `CONFIG` block at the top of the script:

| Setting | Default | What it does |
|---|---|---|
| `title` | Bubble Pop | Game name shown in the tab and settings |
| `clearRows` / `clearColumns` | true / true | Which lines clear |
| `scoring.pointsPerCellPlaced` | 2 | Points per bubble placed |
| `scoring.pointsPerLine` | 100 | Points per cleared row or column |
| `scoring.multiLineMultiplier` | 1, 2, 3, 4, 5, 6 | Several lines in one move multiply: 2 lines = 400, 3 = 900, 4 = 1,600 |
| `scoring.comboStep` | 0.5 | Each consecutive clearing move adds +0.5× |
| `scoring.comboGraceMoves` | 3 | Combo resets after 3 placements with no clear |
| `scoring.boardClearBonus` | 1000 | Frame bonus × frame number (1,000, 2,000, 3,000...) |
| `frames.firstTarget` / `frames.step` | 6 / 2 | Lines needed for frame 1, then +2 per frame (6, 8, 10...) |
| `frames.perfectBonus` | 1500 | Extra for clearing the whole board yourself (also finishes the frame) |
| `assist.easyFrames` | 3 | Helping-hand dealer is strong for the first 3 frames, then eases off |
| `waterfall.trigger` | `boardEmpty` | Extra waterfall triggers on top of frames: `lines` (3+ lines in one move) or `either` |
| `waterfall.durationMs` | 1000 | Length of the waterfall |
| `pieces.fairness` | `solvable` | Guaranteed: all three pieces in every hand can be placed (in some order). Tested over 1,668 hands of random play with zero failures. `one` or `none` make it harder |
| `timing.popStaggerMs` | 42 | Gap between pops in the ripple |
| `haptics.boardClear` | [22, 40, 30] | Vibration pattern on a board clear |

**Score for one clearing move** = lines × 100 × multi-line multiplier × combo multiplier, plus 2 per placed bubble. Finishing a frame adds 1,000 × the frame number; clearing the whole board adds 1,500 more.

**Undo** (`CONFIG.undo.costPercent`, default 10): the arrow in the header takes back the last move for 10% of your score, shown on the button. Also offered on the game-over card.

Bubble styles live in `SKINS` (7 so far: juicy bubbles (default: solid, plump, glossy in hot pink, turquoise, purple, mango and lime), glass bubbles, clear soap bubbles, fizzy bubbles, glass marbles, beach balls, pearls). The style changes after every waterfall. Each is a small drawing function, so adding one is easy. Piece shapes are in `SHAPE_DEFS` with weights.

## Progression: mystery pieces, Frame Bubbles, frames

- **Mystery piece** (`CONFIG.mystery`): every popped line fills the meter under the score (6 lines for the first, then 8). When it fills, a glowing "?" orb drops into the tray. Picking it up reveals a one-off shape built for the board at that moment, aiming to take out 3-5 lines at once, or the whole board when possible. If nothing clever is possible it becomes a random unusual shape (big T, H, U, long L...) that fits.
- **Frame Bubble** (`mystery.frameBubbleAfter`): after 1 ordinary mystery piece (frame 1), 2 (frame 2) or 3 (frame 3+), the next one earned is a golden ★ Frame Bubble. Drop it anywhere: every bubble pops in a chain from that spot and the frame is cleared. Clearing the board yourself also clears the frame. Testing showed full-board clears almost never happen naturally (0 in 40 computer games, even with mystery pieces), which is why frames are earned this way.
- **Frame clear** (`Celebrate`): full-screen celebration on its own layer: flash and shockwave, water and bubbles flung across the screen, screen-wide waterfall, soap bubbles rising and popping, CLEAR! dropping in letter by letter, bonus counting up (3,000 × frame number + 20 per popped bubble), then the rewards: new bubble style, points multiplier for the next frame (×1.5, ×2...), plus an undo or bonus piece when earned.
- **Bonus piece** (`CONFIG.bonusPiece`): earned every 10 frames, saved (up to 3). The gold "Use bonus piece" button drops a mystery piece into an empty tray slot.
- **Undos** (`CONFIG.undo`): saved up, max 3. One free in each of your first 3 games, one free every 5th game, one per 10 frames cleared. Each use also costs 10% of your score.
- **Helping hand** (`CONFIG.assist`): the dealer favours small and line-completing pieces for the first 3 frames, then eases off.

## Look

Near-black ink background (`BG`) with slow colour light drifting at the screen edges and tiny droplets rising in the margins. A soft dark pool sits under the grid so nothing moves behind the play area. The grid has no frame: only faint empty cells. Line clears flash a brief glow along the line, each bubble bursts with a coloured glow, spray and a trickle of falling water. Bigger clears and combos scale the splash up (`intensity`, max 2.4×) and briefly brighten the background light.

## Sound

All synthesised with Web Audio, with a sound-effects volume slider in settings (default 80%). No music. Every sound has slight random pitch and timing variation.

- **Placing a piece:** a soft springy plop, then one quick bubble pop per bubble in the piece.
- **Line clear:** a crisp, juicy splat-splash, then each bubble pops in the ripple, stepping up a pentatonic scale and panned left to right, with a muffled splash and tiny droplets.
- **Combos and multi-line clears:** a short rising water rush with a bubbly cascade on top, longer and brighter as the combo grows.

## Bubble life

Placed bubbles jiggle like soapy water when they land (`wobbleAmount`), nearby bubbles ripple a beat later, every bubble breathes gently, and a rainbow soap-film shimmer slowly turns across them (`sheenSprite`, on skins marked `sheen: true`). Dragged pieces stretch in the direction they move. 

## Testing helpers

Add `#debug` to the URL to get buttons that set up a row clear, two lines, row + column, a board clear, a near-stuck board, and a skin switch. `window.WBP` exposes the state for automated tests.

## Code layout (all in index.html)

`CONFIG` → `SHAPES` → `Logic` (pure rules, no drawing) → `SKINS` → `Store` (localStorage) → `Sound` (Web Audio synthesis) → `Haptics` → game rules (`move`, `newGame`) → render + effects → `Input` (pointer events) → `UI` (DOM).

## Saved on the device

Best score, the game in progress (so a refresh or closed tab resumes), sound/vibration/motion settings, and whether the first-play hint has been seen.

## Known limits

- Sounds are synthesised in the browser. They are a starting point. Recorded samples can replace them later via `Sound`.
- Vibration works on Android. iPhone browsers block the vibration API; the game uses a light iOS 18+ tap where possible. Full iPhone haptics need a native wrapper (e.g. Capacitor) later.
- Not included yet by design: accounts, leaderboards, ads, payments, backend.
