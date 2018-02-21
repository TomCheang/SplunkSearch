# SplunkSearch
search splunk with powershell.  easy to use function here which is a great alternative to splunk web ui.

To get started:

  New-SplunkSearch -search_query 'index=myindex EventCode=4776'

Sends search query to your splunk or splunkcloud server.  default to 24hr period to match default at splunk web.  
