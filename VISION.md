# Vision

`EmberPad` exists so that an Ember tutor can teach a class from worksheets on an iPad with Apple Pencil, the way they already write in GoodNotes, without sending each PDF to the iPad by hand.
It serves the lead tutor who owns this project and the Ember tutors who run the same setup: Ember Slate on the tutor's iPad and Ember Companion on the tutor's Mac.
It turns the worksheets in the Drive EMBER folder into a library on the iPad, the tutor's pen on those worksheets, and the picture the class sees.
It owns exactly one thing: the tutor's ink on a worksheet, from the Pencil to the class screen.

## GoodNotes is the floor

Where a tutor uses a GoodNotes behaviour, Ember Slate matches it, measured against GoodNotes on the iPad: pen width, highlighter colours, eraser sizes, zoom, gestures, header layout and transitions.
Ember Slate goes beyond GoodNotes where a measurement shows a better result for teaching, such as ink that comes out faster or an erase that is more precise.
A better behaviour ships even when it feels different in the hand, and the lead tutor's own testing on the iPad decides whether it stays.
When a choice is open and nothing measured settles it, GoodNotes' answer wins.
Ember Slate wears Ember's colours, name and star mark on GoodNotes' layout.
No GoodNotes binaries, artwork or code are copied, only behaviour.

## Only what teaching uses

Matching GoodNotes is a reason to build a feature teaching uses, not a reason to build every feature GoodNotes has.
A GoodNotes feature with no use in Ember's lessons is left out, as the microphone button, the typed text box, image insertion and split view are.
A GoodNotes feature nobody has asked for is not built until asked, as dragging tabs to reorder is not.
A control the tutor did not choose stays off the screen.

## Built for teaching a class

Ember Slate differs from GoodNotes only where teaching a class needs something GoodNotes does not do.
Each worksheet can have a Teacher copy, and the Teacher button flips the page in place between the two.
The class screen shows a student view of the page and ink, on a projector or on the Mac through Present on Mac.
The library mirrors the Drive EMBER folder, folder for folder, and the Mac prepares it.
The Mac only reads the Drive folder, and worksheets are renamed or moved in Drive, never from the iPad.
One worksheet can sit in several class folders, and a change made to one copy from the iPad would leave the others behind.
The Mac pairing carries the library to the iPad, keeps a copy of the ink, and records the lesson.
Where GoodNotes has no answer, Ember Slate follows the classroom tool the tutor already knows, as Freeze follows a projector remote.

## The class never sees what it should not

The Teacher copy reaches the class only when the tutor flips to it on purpose.
A mirrored or captured screen never shows a Teacher copy by accident.
A lesson recording shows what the class screen showed, so a Teacher copy the tutor flipped to is in the recording too.
Teacher copies are never exported.

## Ink is safe during the lesson and writing never waits

A stroke written in a lesson is kept, through undo, tab switches, page turns, relaunches and slow devices.
Ink comes out under the Pencil at once, and the class screen keeps up.
Nothing clears ink without asking, and keeping it is the default.
After class the tutor usually clears the ink, so keeping ink for the long term is not a goal, and the copy on the Mac is enough.
A fix for a lost stroke or a stall goes to its cause and comes with a test that would have caught it.

## Local and private

The iPad and the Mac talk only to each other, over their own paired link.
There is no server, no account, no cloud sync and no third-party code.
Ember Companion's job ends with a finished lesson file in a known folder on the tutor's Mac.
The video pipeline that edits and publishes lessons stays outside the apps, run by the lead tutor.
The repository is public, so it holds no student, class or account details, and tests use synthetic worksheets.

## Scope

Ember Slate is not a general notes app, not a product for tutors outside Ember, and never on the public App Store.
Free signing with automatic renewal serves one tutor, and a paid developer account with private distribution is acceptable once several Ember tutors use it.
Every tutor runs the same settings, and tuning for one tutor's hand waits until a tutor needs it.
The handover is written down well enough for another Ember tutor to run a whole lesson from it: the iPad, the Mac, the microphone, and where each recording goes so it reaches the lead tutor.
It is not used on students' devices: students bring their own iPads and apps, and Ember Slate does not reach them.
It is not a cloud service, a video editor or a learning platform.

A change aligns when it matches or beats a GoodNotes behaviour a tutor uses, or serves teaching a class where GoodNotes has nothing, while keeping lesson ink safe and the Teacher copy private.
A change should be resisted when it adds a GoodNotes feature teaching does not use, departs from GoodNotes without a measured or classroom reason, puts lesson ink or the Teacher copy at risk, or sends anything off the tutor's own iPad and Mac.
