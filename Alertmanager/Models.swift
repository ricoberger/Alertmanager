//
//  Models.swift
//  Alertmanager
//
//  Created by Rico Berger on 19.10.19.
//  Copyright © 2019 Rico Berger. All rights reserved.
//

import Foundation

struct Config: Codable {
    var refreshInterval: Double
    var severityLabel: String
    var severityInfo: String
    var severityWarning: String
    var severityError: String
    var severityCritical: String
    var titleTemplate: String
    var alertTemplate: String
    var alertmanagers: Alertmanagers
    
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        
        self.refreshInterval = try values.decodeIfPresent(Double.self, forKey: .refreshInterval) ?? 60
        self.severityLabel = try values.decodeIfPresent(String.self, forKey: .severityLabel) ?? ""
        self.severityInfo = try values.decodeIfPresent(String.self, forKey: .severityInfo) ?? "info"
        self.severityWarning = try values.decodeIfPresent(String.self, forKey: .severityWarning) ?? "warning"
        self.severityError = try values.decodeIfPresent(String.self, forKey: .severityError) ?? "error"
        self.severityCritical = try values.decodeIfPresent(String.self, forKey: .severityCritical) ?? "critical"
        self.titleTemplate = try values.decodeIfPresent(String.self, forKey: .titleTemplate) ?? "[{{ name }}] {% for key, value in labels %} {{ key }}: {{ value }} {% endfor %}"
        self.alertTemplate = try values.decodeIfPresent(String.self, forKey: .alertTemplate) ?? "{% for key, value in annotations %} {{ key }}: {{ value }} {% endfor %}"
        self.alertmanagers = try values.decode(Alertmanagers.self, forKey: .alertmanagers)
    }
}

typealias Alertmanagers = [Alertmanager]

struct Alertmanager: Codable {
    var name: String
    var url: String
    var authType: String
    var authUsername: String
    var authPassword: String
    var authToken: String
    
    //init(name: String, url: String, authType: String?, authUsername: String?, authPassword: String?, authToken: String?) throws {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        
        self.name = try values.decode(String.self, forKey: .name)
        self.url = try values.decode(String.self, forKey: .url)
        self.authType = try values.decodeIfPresent(String.self, forKey: .authType) ?? ""
        self.authUsername = try values.decodeIfPresent(String.self, forKey: .authUsername) ?? ""
        self.authPassword = try values.decodeIfPresent(String.self, forKey: .authPassword) ?? ""
        self.authToken = try values.decodeIfPresent(String.self, forKey: .authToken) ?? ""
    }
}

struct AlertmanagerAlerts {
    var name: String
    var url: String
    var alertGroups: [AlertGroup]
}

typealias AlertGroups = [AlertGroup]

public struct AlertGroup: Codable {
    var labels: [String:String]
    var receiver: Receiver
    var alerts: [Alert]
}

public struct Alert: Codable {
    var annotations: [String:String]
    var endsAt: String
    var fingerprint: String
    var receivers: [Receiver]
    var startsAt: String
    var status: AlertStatus
    var updatedAt: String
    var generatorURL: String
    var labels: [String:String]
}

struct Receiver: Codable {
    var name: String
}


struct AlertStatus: Codable {
    enum State: String, Codable {
        case unprocessed = "unprocessed"
        case active = "active"
        case suppressed = "suppressed"
    }
    var state: State
    var silencedBy: [String]
    var inhibitedBy: [String]
}

struct TitleContext: Codable {
    var name: String
    var labels: [String:String]
}