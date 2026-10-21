package plan

// Undo is what apply records about one change so a later undo can reverse it:
// the state the change replaced, in the words of the provider that made it.
// It crosses a process boundary, so it is plain data, never a closure.
type Undo struct {
	Provider string `json:"provider"`
	Target   string `json:"target"`
	Resource string `json:"resource"`
	// Verb is the provider's name for the inverse, such as "restore" or
	// "uninstall".
	Verb string            `json:"verb,omitempty"`
	Data map[string]string `json:"data,omitempty"`
	// Blob is content too sensitive for the journal, such as a dotfile's
	// previous text. The journal stores it in its own 0600 file and keeps the
	// path in Data["blob"].
	Blob []byte `json:"-"`
	// Reason is set when the change cannot be undone, and says why.
	Reason string `json:"reason,omitempty"`
}

// NoUndo is an Undo for a change with nothing to put back, such as a restart:
// undo skips it without a word.
func NoUndo() Undo { return Undo{Verb: "none"} }

// Nothing reports whether u is a NoUndo.
func (u Undo) Nothing() bool { return u.Verb == "none" }

// Irreversible is an Undo for a change that cannot be reversed.
func Irreversible(reason string) Undo { return Undo{Reason: reason} }
