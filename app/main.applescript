-- 双击选择 IPA，或将 IPA 拖到应用图标上。

on run
	set f to choose file with prompt "选择要安装到 Mac 的 IPA 文件：" of type {"ipa", "com.apple.itunes.ipa", "public.data"}
	processIPA(f)
end run

on open theFiles
	repeat with f in theFiles
		processIPA(f)
	end repeat
end open

on processIPA(f)
	set p to POSIX path of f
	if p does not end with ".ipa" then
		display dialog "不是 .ipa 文件：" & return & p buttons {"好"} default button 1 with icon caution
		return
	end if
	set tool to POSIX path of (path to resource "ipa2mac.sh")
	display notification "正在转换并签名…" with title "IPA → Mac" subtitle (name of (info for f))
	try
		set out to do shell script "/bin/bash " & quoted form of tool & " " & quoted form of p & " 2>&1"
		display dialog out buttons {"好"} default button 1 with title "IPA → Mac：完成"
	on error errMsg number errNum
		display dialog errMsg buttons {"好"} default button 1 with icon stop with title "IPA → Mac：失败 (" & errNum & ")"
	end try
end processIPA
