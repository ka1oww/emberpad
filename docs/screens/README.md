# Screen gallery

One picture per screen state of Ember Slate (iPad) and Ember Companion (Mac). Each is named after the section of the
design round's report (`ipad-teaching-app-design`, section 5) that specifies it. They were taken for EP-20 on the
iPad Pro 11-inch (M5) simulator, iOS 26.5, and the Companion's menu-bar window sections were rendered at their 340 pt width. Pictures
are light mode unless the name ends in `-dark`, and are downscaled to about half size.

The content is synthetic test data only (folders "UI Test" and "Synthetic Class", worksheets "Toolbar Drag",
"Second Notebook" and "Synthetic Worksheet"). Simulator builds are unsigned, so the sidebar footer can say "The
Keychain refused the pairing (-34018)" or "Signing expiry unknown"; a signed build on the iPad does not.

| Picture | State | Design section |
|---|---|---|
| `library-all-subjects.png` | Library, All subjects selected, one folder | 5.1 |
| `library-subject.png` | Library, a subject selected, its worksheet grid | 5.1 |
| `library-subject-dark.png` | The same, dark mode | 5.1, 3 |
| `library-portrait.png` | Library in portrait | 5.1 |
| `library-empty.png` | Empty library (first launch) | 5.1.1 Empty |
| `library-importing.png` | Importing PDFs | 5.1.1 Importing |
| `library-error.png` | Library needs attention (error banner) | 5.1.1 Error |
| `library-signing-amber.png` | Signing expires within 48 h (amber banner) | 5.1.1 Amber |
| `library-signing-red.png` | Signing expires tonight (red banner) | 5.1.1 Red |
| `library-signing-unknown.png` | Signing expiry unknown | 5.1.1 Unknown |
| `library-archived.png` | Archived selected | 5.1 |
| `library-sharing.png` | Library while sharing to the student view | 5.1, 5.2 |
| `worksheet.png` | Worksheet, landscape | 5.2 |
| `worksheet-dark.png` | The same, dark mode | 5.2, 3 |
| `worksheet-portrait.png` | Worksheet, portrait | 5.2 |
| `share-pill-sharing.png` | Header share pill: sharing | 5.2 |
| `share-pill-paused.png` | Header share pill: paused | 5.2 |
| `share-pill-mirrored.png` | Header share pill: screen mirrored, answers hidden | 5.2 |
| `../screenshots/ep177/flip-student.png` | Student copy with the Teacher button | 5.3 |
| `../screenshots/ep177/flip-teacher.png` | Flipped in place to the Teacher copy | 5.3 |
| `../screenshots/ep177/flip-teacher-ink.png` | Teacher copy written on | 5.3 |
| `../screenshots/ep177/clear-ink-alert.png` | Clear ink? alert when a lesson ends | 5.3 |
| `../screenshots/ep186/swap-student.png` | Student copy on the page, the Student/Teacher swap in the header, the Teacher copy closed at the side | 5.3 |
| `../screenshots/ep186/swap-teacher.png` | Swapped: Teacher copy on the page, Student copy closed at the side | 5.3 |
| `../screenshots/ep186/slide-over-open.png` | Student copy open in the slide-over beside the Teacher copy | 5.3 |
| `tool-pen-settings.png` | Pen selected, its settings open | 5.4 |
| `tool-highlighter-settings.png` | Highlighter selected, its settings open | 5.4 |
| `tool-eraser-settings.png` | Eraser selected, its settings open | 5.4 |
| `tool-lasso.png` | Lasso selected | 5.4 |
| `tool-toast.png` | Tool toast (Apple Pencil double-tap) | 5.4 |
| `pencil-palette.png` | Pencil tool palette open by the Pencil | 5.4.1 |
| `more-menu.png` | More menu (⋯), page section | 5.6 |
| `student-presenter-page.png` | Student view, Mirror Presenter Page, a rotated page with ink | 5.5 |
| `student-paused.png` | Student view, Paused | 5.5 |
| `student-idle.png` | Student view, no worksheet (the Ember mark) | 5.5 |
| `companion.png` | Mac Companion menu-bar window (iPad not paired) | 5.7 |
| `companion-dark.png` | The same, dark mode | 5.7, 3 |

Where the build follows GoodNotes rather than the design board (the header and notebook tabs, the floating tool
palette, the Teacher copy flipping in place, ink colours and sizes, and the Companion
layout), the pictures show the build as it is. The EP-20 pull request lists each of these choices.
