import Foundation

enum SessionLoadScope {
    case today
    case day(Date)
    case month(Date)
    case all
}
