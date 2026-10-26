-- Creates a 5-slide test deck; slide 3 skipped; notes on each slide.
on run argv
	set outPath to item 1 of argv
	tell application "Keynote"
		activate
		set d to make new document
		tell d
			repeat with i from 2 to 5
				make new slide
			end repeat
			repeat with i from 1 to 5
				tell slide i
					try
						set object text of default title item to "Slide " & i
					end try
					set presenter notes to "Notes for slide " & i & " — ünïcödé ✓"
				end tell
			end repeat
			set skipped of slide 3 to true
		end tell
		save d in POSIX file outPath
		return name of d
	end tell
end run
