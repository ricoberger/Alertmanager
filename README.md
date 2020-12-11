# Alertmanager for macOS

![Alertmanager](assets/screenshot.png)

The **Alertmanager for macOS** is a small macOS application which shows alerts from [Prometheus Alertmanagers](https://github.com/prometheus/alertmanager). You can setup multiple Alertmanager instances to retrive alerts from. The alerts are grouped by the specified settings in you Alertmanager configuration.

## Usage

Download the latest release of the Alertmanager for macOS from the [releases](https://github.com/ricoberger/Alertmanager/releases) page. Unpack the downloaded ZIP file and start the app.

During the first start a file called `.alertmanager.json` will be created in you home directory. Right click on the symbol of the Alertmanager for macOS in the status bar and choose `Open Configuration`. This will open the configuration file in your default editor. After you have adjusted the configuration right click on the symbol again and choose `Reload Configuration`.

An example configuration can be found in the following code block. For all available options take a look at the [configuration](#configuration) section.

```json
{
  "refreshInterval": 60,
  "severityLabel": "severity",
  "severityInfo": "info",
  "severityWarning": "warning",
  "severityError": "error",
  "severityCritical": "critical",
  "titleTemplate": "[{{ name | uppercase }}] [{{ labels['cluster'] | uppercase }}] {{ labels['alertname'] }}",
  "alertTemplate": "{{ annotations['message'] }}",

  "alertmanagers": [
    {
      "name": "PROD",
      "url": "http://localhost:9093"
    }
  ]
}
```

## Configuration

You can configure the following values for the Alertmanager app:

### General

| Value | Description | Default |
| ----- | ----------- | ------- |
| `refreshInterval` | The interval in which the alerts are retrieved. | `60` |
| `severityLabel` | The name of the label for the severity of an alert. | |
| `severityInfo` | Value of the severity label for an info alert. | `info` |
| `severityWarning` | Value of the severity label for an warning alert. | `warning` |
| `severityError` | Value of the severity label for an error alert. | `error` |
| `severityCritical` | Value of the severity label for an critical alert. | `critical` |
| `titleTemplate` | Template for the title. The template can use the name of the Alertmanager and the group labels. (see [Templates](#templates)) | `[{{ name }}] {% for key, value in labels %} {{ key }}: {{ value }} {% endfor %}` |
| `alertTemplate` | Template for a single alert. The template can use the annotations and labels of the alert. (see [Templates](#templates)) | `{% for key, value in annotations %} {{ key }}: {{ value }} {% endfor %}` |
| `themeBg` | Background color. | `#2E3440` |
| `themeBgLight` | Light background color. | `#3B4252` |
| `themeFg` | Foreground color. | `#ECEFF4` |
| `themeInfo` | Info color. | `#5E81AC` |
| `themeWarning` | Warning color. | `#EBCB8B` |
| `themeError` | Error color. | `#D08770` |
| `themeCritical` | Critical color. | `#BF616A` |
| `alertmanagers` | List of Alertmanagers (see [Alertmanager](#alertmanager)). | **Required** |

### Alertmanager

| Value | Description | Default |
| ----- | ----------- | ------- |
| `name` | Name of the Alertmanager. | **Required** |
| `url` | URL of the Alertmanager. | **Required** |
| `silenced` | Show silenced alerts. Must be `true` or `false` as *string*. | `false` |
| `inhibited` | Show inhibited alerts. Must be `true` or `false` as *string*. | `false` |
| `authType` | Authentication method which should be used to retrieve alerts. Possible values are `basic` and `token`. If not authentication is required omit this field. | |
| `authUsername` | If basic auth is used this is the username which should be used. | |
| `authPassword` | If basic auth is used this is the password which should be used. | |
| `authToken` | If token auth is used this is the token which should be used. | |

### Templates

We are using [the Stencil template language](https://stencil.fuller.li/en/latest/) to render the alerts. You can use all built in [tags](https://stencil.fuller.li/en/latest/builtins.html#built-in-tags) and [filters](https://stencil.fuller.li/en/latest/builtins.html#built-in-filters) for your templates.

#### titleTemplate

The `titleTemplate` is used to render the alert group title. The following variables are available in `titleTemplate`:

- `name`: Name of the Alertmanager from the configuration file.
- `url`: URL of the Alertmanager from the configuration file.
- `labels`: Labels which indicates the alert group. This is configured in your Alertmanager with the `group_by` option.

```json
{
  "titleTemplate": "<a href='{{ url }}'>[{{ name | uppercase }}] {{ labels['alertname'] }}</a>"
}
```

#### alertTemplate

The `alertTemplate` is used to render a single alert in the list of alerts. The following variables are available in `alertTemplate`:

- `annotations`: Configured annotations for the alert.
- `labels`: Labels of the alert.
- `generatorURL`: Identifies the entity that caused the alert. 

```json
{
  "alertTemplate": "<a href='{{ generatorURL }}'>{{ annotations['message'] }}</a>"
}
```
