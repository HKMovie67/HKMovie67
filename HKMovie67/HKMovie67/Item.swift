//
//  Item.swift
//  HKMovie67
//
//  Created by Y. Sunny Lai on 3/1/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
