import ApplicationServices
import Foundation

/// File overview:
/// Recognizes a one-line input inside a web page (a form's First Name, Last Name or Job Title
/// box), where Cotabby stands down completely: no ghost, no model request, Tab left alone.
///
/// Why: Cotabby accepts a suggestion with Tab, and in a web form Tab is how a writer moves to the
/// next box. A ghost in such a box hijacks that key, and what such a box holds (a name, a title,
/// a city) is not prose a model can continue anyway. The page owns Tab there, so the whole field
/// is left to it, the same way Mail's header rows are (`MailHeaderFieldDetector`).
///
/// What is NOT a form field here: a multi-line text area (`AXTextArea`) and a contenteditable
/// editor are different roles and keep completing, because they hold prose and Tab inside them is
/// not a "next field" key. A one-line field outside a web page is not judged either: a browser's
/// address bar and every native app's text field stay supported, so the "inside a web page?"
/// answer (an `AXWebArea` ancestor, the same one `SearchFieldDetector` relies on) is what decides.
///
/// Pure: the resolver asks here in two steps (`mightBeFormField`, then `isFormField`) so the
/// ancestry climb, an AX read per ancestor, is made only for a one-line input.
enum FormFieldDetector {
    static let blockedReason = "Form fields are left to the page; Tab moves to the next field."

    /// Cheap pre-check on the role alone: the one-line inputs. `AXComboBox` is a web `<input>` with
    /// a datalist or a combobox role, which is still a single-line box in a form.
    static func mightBeFormField(role: String) -> Bool {
        role == kAXTextFieldRole as String || role == kAXComboBoxRole as String
    }

    /// `isInWebPage` is a closure so a role that is not a one-line input never pays the AX read.
    static func isFormField(role: String, isInWebPage: () -> Bool) -> Bool {
        guard mightBeFormField(role: role) else { return false }
        return isInWebPage()
    }
}
