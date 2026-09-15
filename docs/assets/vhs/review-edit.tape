Output review-edit.gif
Source tapes/start.tape
Sleep 1s
Type "]c"
Sleep 1s
Source tapes/edit.tape
Sleep 2s
Type "[f"
Hide
Type@1ms ":DemoCheck switched"
Enter
Wait+Screen /DEMO_READY_switched/
Type@1ms ":echo ''"
Enter
Show
Sleep 2s
Type "]f"
Hide
Type@1ms ":DemoCheck returned"
Enter
Wait+Screen /DEMO_READY_returned/
Type@1ms ":echo ''"
Enter
Show
Sleep 3s
Screenshot review-edit-final.png
Sleep 500ms
Source tapes/finish.tape
