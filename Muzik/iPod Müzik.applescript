-- Droplet: drop MP3s (or folders) on the app icon to tag them and add them to the Music app.
on open droppedItems
	set args to ""
	repeat with anItem in droppedItems
		set args to args & " " & quoted form of POSIX path of anItem
	end repeat
	display notification "Şarkılar etiketleniyor…" with title "iPod Müzik"
	try
		set report to do shell script quoted form of (POSIX path of (path to me) & "Contents/Resources/muzik.sh") & " --evet" & args
	on error errorMessage
		display dialog "Bir sorun oldu:" & return & return & errorMessage buttons {"Tamam"} default button 1 with title "iPod Müzik" with icon stop
		return
	end try
	display dialog report & return & return & "Telefonu takıp Finder → iPhone → Müzik → Eşzamanla'ya bas." buttons {"Tamam"} default button 1 with title "iPod Müzik"
end open

on run
	set chosen to choose file with prompt "Eklenecek mp3'leri seç" of type {"public.mp3"} with multiple selections allowed
	open chosen
end run
