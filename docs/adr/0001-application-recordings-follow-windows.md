# Application recordings follow windows across displays

Application capture follows the selected application's eligible windows, including newly opened windows, using application-filtered display tracks on a shared session clock. We retain separate tracks when displays appear, disappear, or change geometry so playback can preserve the desktop arrangement and focus on a window without changing the captured evidence. A single chosen window cannot represent an application session; independent per-window capture would lose the observed overlap and placement of its windows.

Window focus shows the recorded pixels in that window's desktop region; it does not recover pixels hidden by another window. Spatial annotations retain their original coordinate frame so a later display change cannot move existing markup.
