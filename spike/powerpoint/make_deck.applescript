-- Builds a 6-slide PowerPoint test deck: slide 3 hidden, notes on each,
-- 3 animations on slide 2, movie on slide 4, two sections.
on run argv
	set outPath to item 1 of argv
	set moviePath to item 2 of argv
	tell application "Microsoft PowerPoint"
		set p to active presentation
		repeat while (count of slides of p) < 6
			make new slide at end of p with properties {layout:slide layout title only}
		end repeat
		repeat with i from 1 to 6
			set s to slide i of p
			set content of text range of text frame of shape 1 of s to "Slide " & i
			set content of text range of text frame of place holder 2 of notes page of s to "Notes for slide " & i & " — ünïcödé ✓"
		end repeat
		set hidden of slide show transition of slide 3 of p to true
		-- builds on slide 2
		set s2 to slide 2 of p
		repeat with k from 1 to 3
			set b to make new shape at end of s2 with properties {auto shape type:autoshape rectangle, left position:(100 * k), top:200, width:80, height:80}
			add effect (main sequence of timeline of s2) for b fx animation type appear
		end repeat
		-- movie on slide 4
		make new movie at end of slide 4 of p with properties {file name:moviePath, left position:100, top:150, width:480, height:270}
		save p in outPath
		return {name of p, count of slides of p}
	end tell
end run
