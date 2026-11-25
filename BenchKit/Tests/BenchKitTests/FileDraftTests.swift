import Foundation
import Testing
@testable import BenchKit

@Test func aFreshDraftIsNotEdited() {
    let draft = FileDraft("one\n")
    #expect(!draft.isEdited)
    #expect(draft.conflict == nil)
}

@Test func typingMakesItEditedAndSavingClearsThat() {
    var draft = FileDraft("one\n")
    draft.edit("one\ntwo\n")
    #expect(draft.isEdited)
    draft.didSave()
    #expect(!draft.isEdited)
    #expect(draft.saved == "one\ntwo\n")
}

@Test func withNoEditsTheEditorFollowsTheDisk() {
    var draft = FileDraft("one\n")
    draft.diskRead("claude's version\n")
    #expect(draft.text == "claude's version\n")
    #expect(!draft.isEdited)
    #expect(draft.conflict == nil)
}

@Test func unsavedEditsSurviveAChangeOnDisk() {
    var draft = FileDraft("one\n")
    draft.edit("mine\n")
    draft.diskRead("claude's version\n")
    #expect(draft.text == "mine\n")
    #expect(draft.conflict == .changed("claude's version\n"))
    // Reading the same thing again changes nothing.
    draft.diskRead("claude's version\n")
    #expect(draft.conflict == .changed("claude's version\n"))
}

@Test func reloadTakesTheDisk() {
    var draft = FileDraft("one\n")
    draft.edit("mine\n")
    draft.diskRead("claude's version\n")
    draft.reload()
    #expect(draft.text == "claude's version\n")
    #expect(!draft.isEdited)
    #expect(draft.conflict == nil)
}

@Test func keepMineStaysEditedAndIsNotAskedAgain() {
    var draft = FileDraft("one\n")
    draft.edit("mine\n")
    draft.diskRead("claude's version\n")
    draft.keepMine()
    #expect(draft.text == "mine\n")
    #expect(draft.isEdited)
    #expect(draft.conflict == nil)
    draft.diskRead("claude's version\n")
    #expect(draft.conflict == nil)
    // A newer change is a new question.
    draft.diskRead("claude's second version\n")
    #expect(draft.conflict == .changed("claude's second version\n"))
}

@Test func theDiskCatchingUpToTheEditsSettlesIt() {
    var draft = FileDraft("one\n")
    draft.edit("mine\n")
    draft.diskRead("other\n")
    draft.diskRead("mine\n")
    #expect(draft.conflict == nil)
    #expect(!draft.isEdited)
}

@Test func theDiskGoingBackSettlesIt() {
    var draft = FileDraft("one\n")
    draft.edit("mine\n")
    draft.diskRead("other\n")
    draft.diskRead("one\n")
    #expect(draft.conflict == nil)
    #expect(draft.isEdited)
    #expect(draft.text == "mine\n")
}

@Test func undoingEveryEditTakesTheNewerFile() {
    var draft = FileDraft("one\n")
    draft.edit("mine\n")
    draft.diskRead("claude's version\n")
    draft.edit("one\n")
    #expect(draft.text == "claude's version\n")
    #expect(draft.conflict == nil)
    #expect(!draft.isEdited)
}

@Test func savingOverAConflictKeepsTheEdits() {
    var draft = FileDraft("one\n")
    draft.edit("mine\n")
    draft.diskRead("claude's version\n")
    draft.didSave()
    #expect(draft.saved == "mine\n")
    #expect(draft.conflict == nil)
    #expect(!draft.isEdited)
}

@Test func aDeletedFileWithEditsIsAConflict() {
    var draft = FileDraft("one\n")
    draft.edit("mine\n")
    draft.diskRead(nil)
    #expect(draft.conflict == .gone)
    draft.keepMine()
    #expect(draft.conflict == nil)
    #expect(draft.isEdited)
    // Still gone: not asked again.
    draft.diskRead(nil)
    #expect(draft.conflict == nil)
    draft.didSave()
    #expect(!draft.isEdited)
}

@Test func aDeletedFileWithNoEditsIsNot() {
    var draft = FileDraft("one\n")
    draft.diskRead(nil)
    #expect(draft.conflict == nil)
    #expect(!draft.isEdited)
}

@Test func aFileThatComesBackIsReadAgain() {
    var draft = FileDraft("one\n")
    draft.edit("mine\n")
    draft.diskRead(nil)
    draft.diskRead("one\n")
    #expect(draft.conflict == nil)
    #expect(draft.text == "mine\n")
    draft.diskRead(nil)
    draft.keepMine()
    draft.diskRead("restored\n")
    #expect(draft.conflict == .changed("restored\n"))
}

@Test func aSaveThatLandsLaterKeepsWhatWasTypedSince() {
    var draft = FileDraft("one\n")
    draft.edit("two\n")
    // Sent to be saved, then more typing before the answer came back.
    draft.edit("two\nthree\n")
    draft.didSave("two\n")
    #expect(draft.saved == "two\n")
    #expect(draft.isEdited)
    // The file arriving as it was saved isn't a conflict.
    draft.diskRead("two\n")
    #expect(draft.conflict == nil)
    #expect(draft.text == "two\nthree\n")
}
