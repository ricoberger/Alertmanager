//
//  ViewController.swift
//  Alertmanager
//
//  Created by Rico Berger on 19.10.19.
//  Copyright © 2019 Rico Berger. All rights reserved.
//

import Cocoa
import WebKit
import Stencil

class ViewController: NSViewController, WKNavigationDelegate {
    // We do not use the NSTextView component, because of some limitions for rendering HTML.
    // @IBOutlet var textView: NSTextView!;
    // @IBOutlet does not work when building the archive, see: https://forums.developer.apple.com/thread/116047.
    // @IBOutlet var webView: WKWebView!;
    var webView: WKWebView!
    // Create the extensions and environment for Stencil. Stencil is used to render our HTML template for the alerts,
    // see: https://stencil.fuller.li/en/latest/
    let environment = Environment()
    
    override func loadView() {
        // Initialize the WKWebView component
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 480, height: 270))
        webView.navigationDelegate = self
        view = webView
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        
        webView.allowsBackForwardNavigationGestures = false
        
        renderAlerts()
    }

    override var representedObject: Any? {
        didSet {
        // Update the view, if already loaded.
        }
    }
    
    func renderAlerts() {
        var output: String = ""
        
        // Check if there was an error while loading the alerts.
        // If yes, we render the error. If no, we build the HTML string for rendering the alerts.
        if Alerts.sharedInstance.error == "" {
            do {
                // Loop through each configured Alertmanager and loaded alert groups and build the HTML output string.
                for alertmanager in Alerts.sharedInstance.alertmanagerAlerts {
                    for alertGroup in alertmanager.alertGroups {
                        output = output + "<div style=\"border-left: 5px solid \(severity(alert: alertGroup.alerts[0])); padding-left: 5px;\">"
                        
                        let titleContext = ["name": alertmanager.name, "labels": alertGroup.labels] as [String : Any]
                        let title = try environment.renderTemplate(string: Alerts.sharedInstance.config.titleTemplate, context: titleContext)
                        
                        output = output + "<p><b>\(title)</b></p>"
                        output = output + "<ul>"
                        
                        for alert in alertGroup.alerts {
                            let contentContext = ["annotations": alert.annotations, "labels": alert.labels] as [String : Any]
                            let content = try environment.renderTemplate(string: Alerts.sharedInstance.config.alertTemplate, context: contentContext)
                            
                            output = output + "<li>\(content)</li>"
                        }
                        
                        output = output + "</ul>"
                        output = output + "</div><hr class=\"divider\">"
                    }
                }
            } catch {
                output = "<div class=\"error\">\(error.localizedDescription)</div><hr class=\"divider\">"
            }
        } else {
            output = "<div class=\"error\">\(Alerts.sharedInstance.error)</div><hr class=\"divider\">"
        }
        
        let text = """
        <html>
        <head>
        <style>
        body {
            background-color: #2E3440;
            color: #ECEFF4;
            font-family: Arial, "Helvetica Neue", Helvetica, sans-serif;
            font-size: 12px;
        }
        a {
            color: #ECEFF4;
            text-decoration: none;
        }
        hr.divider {
            border: 1px solid #3B4252;
        }
        .error {
            background-color: #BF616A;
            padding: 5px;
        }
        </style>
        </head>
        <body>
        <hr class=\"divider\">
        \(output)
        </body>
        </head>
        """
        
        // Create an attributed string out of the HTML string and render these string in the textView component.
        // let htmlData = NSString(string: output).data(using: String.Encoding.utf8.rawValue)
        // let options = [NSAttributedString.DocumentReadingOptionKey.documentType: NSAttributedString.DocumentType.html]
        // let attributedString = try! NSAttributedString(data: htmlData!, options: options, documentAttributes: nil)

        // textView.textStorage?.setAttributedString(attributedString)
        
        webView.loadHTMLString(text, baseURL: nil)
    }
    
    func severity(alert: Alert) -> String {
        // If there is no label for the severity configured we return the "info" color.
        // When the label is configured we return the corresponding color for the levels "info", "warning", "error" and "critical".
        if Alerts.sharedInstance.config.severityLabel == "" {
            return "#5E81AC"
        }
        
        if alert.labels[Alerts.sharedInstance.config.severityLabel] == Alerts.sharedInstance.config.severityInfo {
            return "#5E81AC"
        }
        
        if alert.labels[Alerts.sharedInstance.config.severityLabel] == Alerts.sharedInstance.config.severityWarning {
            return "#EBCB8B"
        }
        
        if alert.labels[Alerts.sharedInstance.config.severityLabel] == Alerts.sharedInstance.config.severityError {
            return "#D08770"
        }
        
        if alert.labels[Alerts.sharedInstance.config.severityLabel] == Alerts.sharedInstance.config.severityCritical {
            return "#BF616A"
        }
        
        return "#5E81AC"
    }
}

