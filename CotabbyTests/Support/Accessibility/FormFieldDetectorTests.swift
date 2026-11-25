import ApplicationServices
import XCTest
@testable import Cotabby

final class FormFieldDetectorTests: XCTestCase {
    private let textField = kAXTextFieldRole as String
    private let comboBox = kAXComboBoxRole as String
    private let textArea = kAXTextAreaRole as String

    func test_oneLineWebInputsAreFormFields() {
        XCTAssertTrue(FormFieldDetector.isFormField(role: textField, isInWebPage: { true }))
        XCTAssertTrue(FormFieldDetector.isFormField(role: comboBox, isInWebPage: { true }))
    }

    func test_webTextAreasKeepCompleting() {
        XCTAssertFalse(FormFieldDetector.isFormField(role: textArea, isInWebPage: { true }))
    }

    func test_textFieldsOutsideAWebPageAreNot() {
        // A browser's address bar and native app fields have no AXWebArea ancestor.
        XCTAssertFalse(FormFieldDetector.isFormField(role: textField, isInWebPage: { false }))
        XCTAssertFalse(FormFieldDetector.isFormField(role: comboBox, isInWebPage: { false }))
    }

    func test_theWebPageCheckIsNotMadeForOtherRoles() {
        var evaluated = false
        let result = FormFieldDetector.isFormField(role: textArea, isInWebPage: {
            evaluated = true
            return true
        })
        XCTAssertFalse(result)
        XCTAssertFalse(evaluated, "A non one-line role must not trigger the ancestry climb")
    }

    func test_onlyOneLineRolesAreWorthTheAncestryClimb() {
        XCTAssertTrue(FormFieldDetector.mightBeFormField(role: textField))
        XCTAssertTrue(FormFieldDetector.mightBeFormField(role: comboBox))
        XCTAssertFalse(FormFieldDetector.mightBeFormField(role: textArea))
        XCTAssertFalse(FormFieldDetector.mightBeFormField(role: "AXWebArea"))
    }
}
