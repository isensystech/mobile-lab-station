# MobileLab-Demo-Story.md — The Lesson

> **Scratchpad. Not a source of truth. Expires after the presentation.**
> **Authority lives in `MobileLab-Arch.md`.**
>
> This document describes a **narrative**, not a capability. Anything here about what the
> lab does is illustration. If it disagrees with `MobileLab-Arch.md`, the arch document
> wins.
>
> **If a decision gets made during prep, write it into `MobileLab-Arch.md` at that
> moment.** Do not leave it here. This document gets deleted.

**For:** Jessica.
**Purpose:** agree the story before we build the demonstration around it.
**Room:** roughly half educators and nonprofits. Not a commercial audience.

---

## 1. What we are showing

Not a device. A **lesson** — one class period, start to finish, that could not be taught
before and now can.

The mobile test lab is what makes the lesson possible. It stays in the background. The
thing on screen is a class working through a question and arriving at an answer that
surprises them.

**One sentence:** a class asks why the water changed, checks the official record, finds it
does not explain what they measured, and works out why.

---

## 2. Why a lesson and not a demonstration

An educator watching a tour of features is asking one question the whole time: *what would
I do with this on Tuesday?*

A feature tour never answers it. A lesson answers nothing else.

And a nonprofit in that room is asking a related question: *what does a community get from
this that it does not already have?* The lesson answers that too, because the answer is
the same — a measurement nobody was making, and the understanding that comes with it.

So we do not present capability. We present forty minutes of a class, and let the
capability be visible underneath it.

---

## 3. The lesson

Three acts. Every number on screen is real. Each act carries one concept.

### Act 1 — What do you notice?

**Concept: observation, and forming a hypothesis.**

**On screen:** a dive from the water quality logger. A salinity dip with clear shape.

**What the class does:** looks at their own data and finds the odd part. The teacher does
not point at it. Students find it, which is the whole difference between being shown a
result and reaching one.

Then the obvious question: what would make salt water less salty? A class gets to fresh
water quickly. Rain. That is a hypothesis, and they built it.

**Roughly what you say:** "This is the class's own dive data. The teacher asks one
question — what do you notice? — and somebody finds this dip. Then: what could cause it?
They get to rain on their own."

### Act 2 — Go and check

**Concept: data source differences. Where does knowledge come from?**

**On screen:** NOAA precipitation for that location and time, on the same axis. Little or
no rain.

**What the class does:** tests the hypothesis against an authoritative public record. This
is the step schools almost never get to do, because the join between a student's
measurement and a public dataset is normally out of reach.

And then the record says no. It barely rained.

**This is the most valuable moment in the lesson.** The class did everything right and got
an answer that does not fit. That is what real inquiry feels like, and it is exactly the
experience a worksheet cannot produce. Most school science ends with the expected result.
This one does not, and the students have to keep going.

**Roughly what you say:** "So they check. This is the official rainfall record — real
public data, the same source a scientist would use. And it says it barely rained. The
class is now stuck, which is the best thing that can happen in a science lesson."

### Act 3 — Accuracy is not the same as scale

**Concept: resolution. Authoritative does not mean complete.**

**On screen:** the class's own rain gauge reading, taken at the site and entered by hand,
appearing on the same axis. It shows rainfall.

**What the class does:** compares two sources that disagree, and works out *why* they
disagree — not which one is lying. The public record covers a large area and reports an
average across it. The gauge covers one schoolyard. A storm that soaks one block and
misses the next disappears into the average.

Neither source is wrong. They are answering different questions. **That is a genuinely
difficult idea, and this lesson makes it concrete in about five minutes.**

**Roughly what you say:** "Then somebody remembers they read the gauge that afternoon. It
rained here. The official record is not wrong — it works at a scale that cannot see one
storm over one creek. The students just found the limit of a national dataset using a
thirty dollar instrument, and they can explain why it happened."

---

## 4. What this teaches that is hard to teach otherwise

Worth being explicit, because this is the part the educators in the room are actually
evaluating.

| Concept | How the lesson delivers it |
|---|---|
| **Correlation, and lag** | Rain and salinity are related, and the effect arrives after the cause. Students see the delay on the axis instead of being told about it. |
| **Data source differences** | Two real sources, same phenomenon, different answers. Not a hypothetical. |
| **Accuracy versus scale** | The disagreement has a cause, and the cause is resolution. The most transferable idea in the lesson. |
| **Authority is not completeness** | A national dataset was incomplete for their creek. Students learn to ask what a source can and cannot see, which generalizes far beyond science class. |
| **Their measurement counts** | A student's hand-written number resolved something an official record could not. That is not a motivational poster. It happened on screen. |

The last one is the reason this matters for the nonprofits in the room. The places where
gridded data is thinnest are the places nobody has instrumented, and those tend to be the
same communities that are underserved in every other respect. A cheap instrument and a
student who knows how to use it puts a real measurement where there was none.

**We should also name what the lesson does not do.** It does not prove causation. Rain
correlates with the dip and the mechanism is plausible, but a single event is not proof.
That caveat is on screen permanently in the lab, and a teacher can build a whole second
lesson on it.

---

## 5. Why this room in particular

**It is one class period.** Not a unit, not a semester project. A teacher can picture
Tuesday.

**It works with one instrument and one student.** No lab, no cohort, no budget for a
sensor per child.

**The hero is the cheap part.** What resolves the lesson is a hand-entered number off an
inexpensive gauge. Every school can afford the thing that mattered most.

**It is local.** The lagoon system here has documented, funded, visible water quality
problems. Students are not analyzing a dataset from somewhere else. It is their water, and
the adults around them are already arguing about it.

**Nothing needs defending.** Real dive, real public record, real gauge reading. There is no
point in the lesson where we skipped something.

---

## 6. Choices we made, and why

These will come up.

### Why salinity, and not pH or temperature

Salinity moves fast and in a direction anybody can follow. Fresh water in, salinity down.
No explanation required, so the lesson spends its time on the interesting part.

Temperature was the alternative. Easier to demonstrate, but temperature explained by air
temperature is close to circular, and students learn less from it. pH we ruled out — it can
be moved with vinegar, but that reads as a chemistry trick rather than an environmental
measurement, and it responds too slowly to hold a class.

### Why act 2 cannot be cut

It is the longest act with the least to look at, so it is the one that gets trimmed for
time. It must not be.

Without act 2, act 3 is two lines moving together — a correlation, and a dull one. With
act 2, act 3 is a resolution to a problem the class could not solve. The entire
educational value sits in the gap between the two.

### Why act 3 uses a real gauge reading

An earlier version of this script modelled the gauge data, because we do not have a
station deployed.

That put the only invented number at the exact point the lesson turns on. For a room of
educators that is worse than a commercial audience, not better — teachers are being asked
to trust this in front of their students, and a fabricated result at the climax is
precisely the thing that would stop them.

We still build the simulator. It is a test fixture that lets us develop the comparison
view before matched real datasets exist. It is labelled as simulated wherever it appears,
and it is not in the lesson.

### Why we never say the public record is wrong

NOAA is doing its job correctly at its scale. Gridded rainfall products are built to cover
large areas and cannot resolve a single convective cell. That is a known limitation, not
an error.

Beyond accuracy, this matters pedagogically. **"The official source is wrong" teaches
cynicism. "The official source has a resolution limit, and here is what it is" teaches
judgment.** The second is the lesson. The first would undermine it.

### Why we describe the teaching layer rather than demonstrate it

Two articles sit beside the charts. We do not show tutorials that build themselves from a
student's own data, because we have not built that.

Showing a real lesson working end to end, and then saying "this is what the teaching layer
plugs into," is more credible than demonstrating half of it. Educators are unusually good
at spotting a half-built feature, and unusually forgiving of an honestly described one.

---

## 7. Rules for the room

1. **Never say the public record is wrong.** Say it works at a scale that cannot see a
   local storm. See §6.
2. **Say when something is not built.** If asked about a deferred capability, the answer
   is "that is the next phase," said plainly. We are asking for support to build more.
3. **Never present simulated data as real.** It is not in this lesson, so it should not
   come up. If it ever does, name it out loud.
4. **Keep the students in the sentences.** Not "the lab detects a correlation" but "the
   class finds the dip." The lab is the instrument, not the protagonist.

---

## 8. Questions we should expect

**"How long does this take?"**
One period for the lesson as shown. The data collection happens beforehand, over days or
weeks, in short sessions.

**"What age group?"**
Middle school and up. Younger students can run acts 1 and 3. The resolution argument in
act 3 is where older students get the most from it.

**"What do the students actually do?"**
Read an instrument, type the number in, pick their name, and watch their measurement
appear alongside everybody else's. Then ask whether it relates to something else.

**"What if the class does not find a disagreement?"**
Then they find agreement, and that is also a result. The lesson works either way — the
public record either explains their measurement or it does not, and both are worth
understanding. A lesson that only works when something anomalous happens would be a bad
lesson, so we did not build one.

**"Does it need internet?"**
No. It records locally and syncs when it finds a connection. Public reference data is
stored on the device beforehand.

**"How does this fit our standards?"**
It maps directly onto the science and engineering practices — analyzing and interpreting
data, using computational thinking, and arguing from evidence. We can produce a proper
alignment document, and we would want a teacher's help writing it.

**"Do we need one per student?"**
No. One lab serves a class. Students take turns on the instruments and share the dataset,
which is closer to how field science actually works anyway.

**"How much of this is automated?"**
The logger and GPS. Everything else is entered by hand, by design. The student who reads
the instrument and types the number is the one who learns something. When we automate a
sensor later, hand entry stays, so a class can compare their own reading against the
instrument's — which is another lesson.

**"Could a student's data ever be used for real?"**
That is the direction we want to go, and there are working precedents for volunteer and
student measurements feeding real science. It needs calibration records and siting
documentation before anyone should rely on it. We have designed so as not to rule it out.

---

## 9. What we need from Jessica

1. **Agree the three acts**, or say where they lose you.
2. **Agree that act 2 stays** even under time pressure. It is the one most likely to be
   cut and the one that must not be. See §6.
3. **Agree the framing rule in §7.1.** It is the easiest thing to lose in a live room and
   the most costly.
4. **Decide who runs the room** and who takes the questions in §8.
5. **Flag anything that oversells.** You know this audience better than this document
   does. If a line promises more than we can build, it comes out now.

---

## 10. Where the data comes from, and the swap deadline

**Jessica should read this section.** It is the one place where what we present could
differ from what we intended, and it is better discussed now than discovered on the day.

The lab is being built against **simulated data**. That is deliberate. It lets us build
and prove the lesson screen before the real measurements exist. The simulator is seeded
and repeatable, so the same series comes back every time.

Real data replaces it in two pieces:

| Piece | Act | Source | Status |
|---|---|---|---|
| Logger dive with the salinity dip | 1 | existing dive records | expected, low risk |
| Rain gauge readings covering that same window | 3 | hand-collected on site | **the real risk** |

The gauge readings cannot be manufactured or recovered later. They have to be taken, at
the site, during the same window as the dive.

### The banner

The lab marks simulated data on screen. A dashed line and a standing SIMULATED notice
that does not go away. That is a deliberate rule and it protects everybody — it is how we
guarantee that nobody, in any room, ever mistakes a modelled number for a measured one.

**It also means we cannot quietly present simulated data as real.** If the gauge readings
are not in by the deadline below, the notice is on screen during act 3, which is the exact
moment the lesson turns on a real hand-read measurement. The screen would contradict the
script.

That is the rule working correctly. But it means the decision has to be made in advance.

### Deadline: the 19th

If real gauge readings covering the dive window are not in by the **19th**, we choose one
of these two. Both work. Neither is a failure.

**Option A — the agreement version.** Run the lesson with a window where the public record
and our gauge agree. The class still measures, still checks the public record, still
compares. What they find is that the two match, which is a real and useful result. The
lesson loses its surprise. It keeps its structure and every concept in §4 except the
resolution argument, which becomes a discussion rather than a demonstration.

**Option B — name it in the room.** Run the lesson as written and say plainly that the
gauge series is modelled, because the station is not deployed yet, and that this is
exactly what the deployed lab replaces. Educators are forgiving of an honestly described
gap and unforgiving of a discovered one. The SIMULATED notice on screen then supports us
rather than undercutting us — it demonstrates that the lab refuses to let anyone confuse
the two.

**Jessica's call, made before the 19th, not on the day.** If we are running Option B, the
line needs to be in the script and rehearsed, not improvised.

---

## 11. Still open

- **Which dive carries the excursion.** We need one with an unambiguous dip that has
  visible shape. A flat profile has no lesson in it. Pending review of the logger CSVs.
- **Gauge readings covering that dive's window.** See §10. The one item with no
  engineering workaround.
- **Whether a teacher reviews the lesson before we present it.** Strongly worth doing. An
  educator will find the thing that does not survive a real classroom, and we would rather
  hear it now.
- **Presentation date.**