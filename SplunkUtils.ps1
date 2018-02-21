
function New-SplunkSearch {
  <#
  .Synopsis
    Main function #1
    Sends ad-hoc query to splunk cloud, watches progress and obtains results
  .DESCRIPTION
    Main function #1
    Sends ad-hoc query to splunk cloud, watches progress and obtains results.
    You must have a valid splunk query string and provide several inputs such as
    dates for the search window along with your credentials.  You'll be able to
    watch the progress of your search job as reported back from splunk server via
    REST calls every 250ms.  Alternatively, sending report out to a file is
    possible by specifying OutFile and output_mode parameters.
  .PARAMETER search_query
    Provide a valid search query.  No validation will be performed.
  .PARAMETER Credential
    Username does not include domain suffix.  Provide your unixname or
    username that has access to splunk, which may not necessarily be your admin
    account.  To avoid being prompted for credentials, create a PSCredential
    via Get-Credential.
  .PARAMETER earliest_time
  This beginning of your search window.  Valid input is any string which can be
  casted as a [datetime] object.  Alternatively, you can use Get-Date to capture
  to a variable.
  .PARAMETER latest_time
  This end of your search window.  Valid input is any string which can be
  casted as a [datetime] object.  Alternatively, you can use Get-Date to capture
  to a variable.  $now = Get-Date
  .PARAMETER OutFile
  Provide a vaild file path.  Search results are sent to disk.
  .PARAMETER output_mode
  Default value is json.  Other values include csv and xml.  Additional values
  can be accepted by Splunk API but not implemented here.
  .EXAMPLE
  $search_query = 'index=corp source="WinEventLog:Security" EventCode=5125'

  $oldest = Get-Date '1/1/2018'
  $now = Get-Date
  $MyCred = Get-Credential

  $SplunkResult = New-SplunkSearch -search_id -earliest_time $oldest

  Get splunk results for $search_query with search window from beginning of 2018
  thru now
  #>
  Param(
    [Parameter(Mandatory=$true)]
    [string]$search_query,
    [PSCredential]$Credential,
    [datetime]$earliest_time = (Get-Date).AddHours(-24),
    [datetime]$latest_time = (Get-Date),
    [Parameter(Mandatory=$false, ParameterSetName='Output To File')]
    [ValidateScript({Test-Path -Path (Split-Path -Path $_ -Parent)})]
    $OutFile,
    [Parameter(Mandatory=$false, ParameterSetName='Output To File')]
    [ValidateSet('csv', 'json', 'xml')]
    $output_mode = 'json',
    $hostname # = '<your instance>.splunkcloud.com'
  )
  Try {
    # suspend validation for self-signed cert at fb.spunkcloud.com:8089
    Suspend-CertificateValidationForSelfSignedSSL

    if (-not $Credential) {
      # if Credential not provide, try to populate username with non-admin acct
      $emp_num = Get-ADUser -Identity $env:UserName -Properties EmployeeNumber |
        select @{n='usr_num';e={$_.EmployeeNumber -replace '999999'}} |
        select -ExpandProperty usr_num

      $usr = Get-ADUser -Filter {EmployeeNumber -eq $emp_num}
      $splSplunkCred = @{
        Username = $usr.SamAccountName
        Message = 'Enter Splunk creds.'
      }
      $Credential = Get-Credential @splSplunkCred
    }
    # search string must begin with search keyword
    if ($search_query -notlike 'search *'){
      $search_query = 'search ' + $search_query
    }
    $Uri = New-Object System.UriBuilder('https', $hostname)
    $Uri.Path = 'services/search/jobs'
    $Uri.Port = '8089'

    # prepare time range
    $earliest = Get-Date $earliest_time -Format s
    $latest = Get-Date $latest_time -Format s

    $search_params = @{
      search = $search_query
      earliest_time = $earliest
      latest_time = $latest
    }

    $splStartSearch = @{
      Uri = $Uri.ToString()
      Method = 'Post'
      Body = $search_params
      ContentType = 'application/x-www-form-urlencoded'
    }
    $job = Invoke-RestMethod @splStartSearch -Credential $Credential
    $search_id = $job.response.sid

    Write-Host "search_id: $search_id"
    Write-Host "search window start: $earliest_time"
    Write-Host "search window end  : $latest_time `r`n`r`n"

    # Display search progress, check every 250 ms
    Do {
      $status = Get-SplunkSearchProgress -search_id $search_id -Credential $Credential

      # account for when value is null
      if (-not $status.doneProgress) {
          $percent = 0
      }
      else {
        $percent = [float]$status.doneProgress * 100
      }

      # run duration measured at splunk cloud
      $activity_msg = "Performing Splunk Search: $($status.eventCount) events" +
        " found  `(search window $earliest .. $latest`)"
      $msg = "stage: $($status.dispatchState) |  run time: $($status.runDuration)"
      $splProgressBar = @{
        Activity = $activity_msg
        Status = $msg
        PercentComplete = $percent
      }
      Write-Progress @splProgressBar
      Start-Sleep -Milliseconds 250
    } While ($status.isDone -eq 0 -or $status.isFailed -eq 1)

    # if job failed, return reason why else get results
    if ($status.isFailed -eq 1) {
      Write-Warning "Search server has reported error in search job."
    }
    else {
      Write-Host "Search complete.  Downloading $($status.resultCount) results.."
      $splGetReport = @{
        search_id = $search_id
        output_mode = $output_mode
        Credential = $Credential
      }
      if ($OutFile) {
        $splGetReoprt.OutFile = $OutFile
        Write-Host "file location: $OutFile"
      }

    Get-SplunkSearchResults @splGetReport
    }
  }
  Catch {
    Write-Error $_
  }
  Finally {
    Restore-CertificateValidationForSelfSignedSSL
  }
}

function Get-SplunkScheduledReportJob {
  <#
  .Synopsis
    Main function #2
    Queries splunk server for all Saved Searches (Reports).  Can also filter
    results by author or return properties of a specific job
  .DESCRIPTION
    Main function #2
    Queries splunk server for all Saved Searches (Reports).  Can also filter
    results by author or return properties of a specific job.

    TODO: filter by report name
  .PARAMETER author
  return jobs created by $author (username)
  .PARAMETER search_id
    search_id for any given Saved Search is different on every job run.  This
    parameter is likely to be used if you're checking on status of a particular
    scheduled report.
  .PARAMETER Credential
    Username does not include domain suffix.  Provide your unixname or
    username that has access to splunk, which may not necessarily be your admin
    account.  To avoid being prompted for credentials, create a PSCredential
    via Get-Credential.

  .EXAMPLE

  $Reports = Get-SplunkScheduledReportJobs -author tomcheang -Credential $cred

  Gets all saved searches authored by tomcheang.
  .EXAMPLE
  $ALL_Reports = Get-SplunkScheduledReportJob -Credential $cred

  Gets all saved searches by all users.
  #>
  [Alias('Get-SplunkSearchJob', 'Get-SplunkSavedSearch')]
  Param (
    [Parameter(Mandatory=$false, ParameterSetName='Jobs authored by')]
    [string]$author,
    [Parameter(Mandatory=$false, ParameterSetName='ReturnOnlyRequestedSearch')]
    [Alias('sid', 'id')]
    [string]$search_id,
    [PSCredential]$Credential,
    $hostname # = '<your instance>.splunkcloud.com'
  )
  # suspend validation for self-signed cert at fb.spunkcloud.com:8089
  Suspend-CertificateValidationForSelfSignedSSL
  if (-not $Credential) {
    Get-Credential -Username $env:Username -Message 'Enter Splunk creds'
  }

  $Uri = New-Object System.UriBuilder('https', $hostname)
  if ($search_id) {
  $Uri.Path = "services/search/jobs/$search_id"
  }
  else {
    $Uri.Path = 'services/search/jobs'
  }
  $Uri.Port = '8089'
  $splRetrieveRecentJobs = @{
    Uri = $Uri.ToString()
    Method = 'Get'
    ContentType = 'application/x-www-form-urlencoded'
  }
  $response = Invoke-RestMethod @splRetrieveRecentJobs -Credential $Credential |
    sort published -Descending

  if ($author) {
    return $response | where {$_.author.name -eq $author} | select *,
      @{n='search_id';e={($_.id -split '/')[-1]}}, @{n='resultCount';
      e={Find-SplunkXmlKey -xml_data $_.OuterXml -key resultCount}}
  }
  else {
    return $response | select *, @{n='search_id';e={($_.id -split '/')[-1]}},
      @{n='resultCount';e={
        Find-SplunkXmlKey -xml_data $_.OuterXml -key resultCount}}
  }
}

function Get-SplunkSearchResults {
  <#
  .Synopsis
    Main function #3
    Queries splunk server for results of given Scheduled Report.
  .DESCRIPTION
    Main function #3
    Queries splunk server for results of given search_id.  The search_id is
    obtained by requesting Saved Searches via Get-SplunkScheduledReportJob.
  .PARAMETER search_id
    search_id for any given Saved Search is different on every job run. The
    search_id is obtained by requesting Saved Searches via
    Get-SplunkScheduledReportJob.

    examples of search_ids and can be really long:
    1516838904.255013_8EE35DD1-09F9-4B80-BDDE-81AD7FD9D3B5
    scheduler__tomcheang__search__RMD5073e7fea320d4ff7_at_1516762800_37681_B...
  .PARAMETER Credential
    Username does not include domain suffix.  Provide your unixname or
    username that has access to splunk, which may not necessarily be your admin
    account.  To avoid being prompted for credentials, create a PSCredential
    via Get-Credential.
  .EXAMPLE

  $Reports = Get-SplunkScheduledReportJob-author tomcheang -Credential $cred

  $results = Get-SpunkSearchResults -search_id $Reports[0].search_id
      -Credential $cred

  This example gets all the jobs authored by tomcheang.  Reports are ordered by
  newest Published time first.  This function gets all results for that
  scheduled report.
  #>
  Param(
    [Parameter(Mandatory=$true)]
    [string]$search_id,
    [PSCredential]$Credential,
    [Parameter(Mandatory=$false, ParameterSetName='Output To File')]
    [ValidateScript({Test-Path -Path (Split-Path -Path $_ -Parent)})]
    $OutFile,
    [Parameter(Mandatory=$false, ParameterSetName='Output To File')]
    [ValidateSet('csv', 'json', 'xml')]
    $output_mode = 'json',
    $hostname # = '<your instance>.splunkcloud.com'
  )
  # suspend validation for self-signed cert at fb.spunkcloud.com:8089
  Suspend-CertificateValidationForSelfSignedSSL

  # get properties of search_id, including resultCount used in paging resultset
  $splGetJobProperties = @{
    search_id = $search_id
    Credential = $Credential
  }
  $job = Get-SplunkScheduledReportJob @splGetJobProperties

  $Uri = New-Object System.UriBuilder('https', $hostname)
  $Uri.Path = "services/search/jobs/" + $search_id + "/results"
  $Uri.Port = '8089'
  $offset = 0
  $body = @{output_mode='json';count='0'}
  $splJobStatus = @{
    Uri = $Uri.ToString()
    Method = 'Get'
    Body = $body
    ContentType = 'application/x-www-form-urlencoded'
    TimeoutSec = '120'
    Credential =  $Credential
  }
  if ($OutFile) {
    $splJobStatus.OutFile = $OutFile
  }

  $ResultSet = New-Object System.Collections.ArrayList

  Do {
    $response = Invoke-RestMethod @splJobStatus
    if ($response.results) {
      foreach ($r in $response.results) {
        $ResultSet.Add($r) | Out-Null
      }
    }

    $offset += 50000 #max page size
    $body = @{output_mode=$output_mode;count='0';offset=$offset}
    $splJobStatus.Body = $body
  } While ($offset -lt $job.resultCount)
  return $ResultSet
}


# helper function
function Find-SplunkXmlKey {
  Param(
    #extracts field info from OuterXml field of splunk job object
    $xml_data,
    $key = 'resultCount'
  )
  $xml = New-Object -TypeName XML
  $xml.LoadXml($xml_data)

  $xml.entry.content.dict.key | where {$_.name -eq $key} |
    select -ExpandProperty '#text'
}

# helper function
function Suspend-CertificateValidationForSelfSignedSSL {
  # ignores self-sign cert.  setting does not persist on system
  Param(
  )
  $IsTypeAdded = "ServerCertificateValidationCallback" -as [type]

  if (-not $IsTypeAdded) {
  $code_block = @"
    using System;
    using System.Net;
    using System.Net.Security;
    using System.Security.Cryptography.X509Certificates;
    public class ServerCertificateValidationCallback
    {
       public static void Ignore()
       {
           ServicePointManager.ServerCertificateValidationCallback +=
               delegate
               (
                   Object obj,
                   X509Certificate certificate,
                   X509Chain chain,
                   SslPolicyErrors errors
               )
               {
                  return true;
               };
         }
     }
"@
    Add-Type -TypeDefinition $code_block
  }
  [ServerCertificateValidationCallback]::Ignore();
}

function Restore-CertificateValidationForSelfSignedSSL {
  [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $null
}

# helper function
function Get-SplunkSearchProgress {
  Param(
    $search_id, $Credential,
      $hostname # = '<your instance>.splunkcloud.com'
  )
  Begin {
    # define custom columns
    $resultCount = @{
      n = 'resultCount'
      e = {Find-SplunkXmlKey -xml_data $_.OuterXml -key resultCount}
    }
    $label = @{
      n = 'label'
      e = {Find-SplunkXmlKey -xml_data $_.OuterXml -key label}
    }
    $search_id_column = @{
      n = 'search_id'
      e = {Find-SplunkXmlKey -xml_data $_.OuterXml -key sid}
    }
    $doneProgress = @{
      n = 'doneProgress'
      e = {Find-SplunkXmlKey -xml_data $_.OuterXml -key doneProgress}
    }
    $isDone = @{
      n = 'isDone'
      e = {Find-SplunkXmlKey -xml_data $_.OuterXml -key isDone}
    }
    $isFailed = @{
      n = 'isFailed'
      e = {Find-SplunkXmlKey -xml_data $_.OuterXml -key isFailed}
    }
    $isFinalized = @{
      n = 'isFinalized'
      e = {Find-SplunkXmlKey -xml_data $_.OuterXml -key isFinalized}
    }
    $sid =  @{
      n = 'sid'
      e = {Find-SplunkXmlKey -xml_data $_.OuterXml -key sid}
    }
    $OptimizedSearch = @{
      n = 'OptimizedSearch'
      e = {Find-SplunkXmlKey -xml_data $_.OuterXml -key OptimizedSearch}
    }
    $isEventsPreviewEnabled = @{
      n = 'isEventsPreviewEnabled'
      e = {Find-SplunkXmlKey -xml_data $_.OuterXml -key isEventsPreviewEnabled}
    }
    $eventAvailableCount = @{
      n = 'eventAvailableCount'
      e = {Find-SplunkXmlKey -xml_data $_.OuterXml -key eventAvailableCount}
    }
    $eventCount = @{
      n = 'eventCount'
      e = {Find-SplunkXmlKey -xml_data $_.OuterXml -key eventCount}
    }
    $runDuration =@{
      n = 'runDuration'
      e = {Find-SplunkXmlKey -xml_data $_.OuterXml -key runDuration}
    }
    $isPreviewEnabled = @{
      n = 'isPreviewEnabled'
      e = {Find-SplunkXmlKey -xml_data $_.OuterXml -key isPreviewEnabled}
    }
    $dispatchState = @{
      n = 'dispatchState'
      e = {Find-SplunkXmlKey -xml_data $_.OuterXml -key dispatchState}
    }
  }
  Process {
    $Uri = New-Object System.UriBuilder('https', $hostname)
    $Uri.Path = "services/search/jobs/$search_id"
    $Uri.Port = '8089'

    $splQueryStatus = @{
      Uri = $Uri.ToString()
      Method = 'Get'
      ContentType = 'application/x-www-form-urlencoded'
    }
    Invoke-RestMethod @splQueryStatus -Credential $Credential |
      select $search_id_column, $sid, $resultCount, $label, $doneProgress,
      $isDone,$isFailed, $isEventsPreviewEnabled, $isFinalized,
      $isPreviewEnabled, $OptimizedSearch, $eventCount, $runDuration,
      $dispatchState
  }
}
#endregion
