import Foundation

enum SessionLoadScope: Equatable {
    case today
    case day(Date)    // startOfDay
    case month(Date)  // first day of month
    case all
}

