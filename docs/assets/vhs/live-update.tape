Output live-update.gif
Source tapes/start.tape
Sleep 2s
Hide
Type@1ms ":DemoWrite updated"
Enter
Type@1ms ":DemoCheck updated"
Enter
Wait+Screen /DEMO_READY_updated/
Type@1ms ":echo 'External edit: modified marker changed to M'"
Enter
Show
Sleep 2s
Source tapes/edit.tape
Sleep 2s
Hide
Type@1ms ":DemoWrite external"
Enter
Type@1ms ":DemoCheck external"
Enter
Wait+Screen /DEMO_READY_external/
Type@1ms ":echo 'External edit: fallback changed to ?; unsaved buffer kept'"
Enter
Show
Sleep 3s
Screenshot live-update-final.png
Sleep 500ms
Source tapes/finish.tape
