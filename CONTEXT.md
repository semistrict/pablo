# Pablo recordings

Pablo preserves observed application activity so a person or agent can review what happened.

## Language

**Application recording**:
A recording of one application's capture-eligible windows and interactions as those windows open, move, and close.
_Avoid_: Largest-window recording

**Window**:
An application's independently positioned visual surface, with an identity and a lifetime within a recording.
_Avoid_: Application

**Video track**:
A continuous recorded view with a defined location and interval on the recording's shared timeline.
_Avoid_: Recording (when referring to only one view)

**Recording canvas**:
The desktop coordinate space in which a recording's visual tracks and windows are arranged.

**Window focus**:
A replay view that follows a selected window while keeping the same recording time.
_Avoid_: Separate recording
