
<#
	.SYNOPSIS
		 Script will scan all shares on a list of given servers to scan for files left by known variants of Cryptowall (including latest Cryptowall 2.0). 
		Will e-mail alert if newly encrypted files are found.
		This script can be scheduled daily/hourly/etc., and more importantly, can be ran with overlapping times such that one instance does not impact the other,
		and new alerts from one will be seen by a simultaneously running instance that finds the same files later on. Therefore, on a file server with many shares you could run the script hourly and even if it takes 12 hours to complete, there would be 12 iterations at different levels of the file system, some at the beginning and some nearing the end of their scan. 
	.DESCRIPTION
		 Script to poll AD for all computers in a given target OU, then poll each said system to determine if it is online, gather basic statistics, 
	.PARAM ComputerName
		List (in array form) of one or more servers to scan - can be used as-is within script
	.PARAM SkipList
		List in array form of full UNC paths of duplicate shares on same server that we should just skip - (not case sensitive), do not include trailing \
	.PARAM $EmailSMTP
		E-mail SMTP server
	.PARAM $EmailTo
		E-mail To address
	.PARAM $EmailFrom
		E-mail From address
	.PARAM $EmailSubject
		E-mail Subject Line
	.EXAMPLE
		.\CryptowallScan.ps1 -ComputerName @() -ExplicitUNCList @("\\netappflr01\puball\a","\\netappflr01\pubacct\Ashley")
		Get-ADComputer -Filter 'Name -like "NYC*"' | select name | .\CryptowallScan.ps1
		
		In .bat, if adding parameters escape the " as \": 
		For a daily/hourly/etc. scheduled task, create a .bat with: powershell.exe -ExecutionPolicy Bypass -NoLogo -NoProfile  -Command "\\contoso.com\scripts\powershell\Cryptowall\cryptowallscan.ps1"
		For very large shares it may be better to have 2 scheduled tasks, one that scans everything and another that calls an explicitUNC list to a specific path 
		or two in the larger share, such as a honeypot directory or an alphabetically early directory in the share; then run the explicit as frequently as possible. 
		In .bat files, escape parameters being sent in with quotes as \", such as (this example has 0 computers named, 2 explicit UNC paths to check and that's it):		
		powershell.exe -ExecutionPolicy Bypass -NoLogo -NoProfile  -Command "\\contoso.com\scripts\powershell\Cryptowall\cryptowallscan.ps1 -ComputerName @() -ExplicitUNCList @(\"\\netappflr01\pubacct\Ashley\",\"\\netappflr01\puball\a\")"
	.Notes
		.Author 
		Dane Kantner 10/15/2014 - Cryptowall file scan - determines if cryptowall was ran and files on share were encrypted, sends e-mail alert for newly found locations
		Designed to be ran on a schedule on a somewhat frequent basis for early detection.
		10/22/2014 - First public release/ added cryptowall 2.0 files.
		10/22/2014 rev B- Added file owner/date; Converted to run-space
		10/24/2014-explicitURLlist parameter added to scan explicit UNC paths; can leave computername list empty and use this only as well. 
						Also very useful if you have a TB+ share that takes a long time to traverse, can run a different instance with only
						a few key early alphabet letters, honeypot directory, or random small folders that get checked on a very frequent basis.
						Fixed begin/process/end piping from ad-objects to script
						Fixed issues with hidden shares on older versions of windows causing no shares to result at all,
						fixed issue Powershell v2 exiting before all jobs completed
#>


#pre-req: ActiveDirectory components for posh
[cmdletbinding()]
Param(
	#Servers to check
	[Parameter(Mandatory=$false, ValueFromPipeLineByPropertyName=$true,ValueFromPipeLine=$true)]
	[alias("name")]
	$ComputerName=@(),	
	#example:
	#$ComputerName=@("nycwinfs03","nycwinfs02","chinetapp01","laxnetapp01","contoso.com"),	#better to leave empty and pass as parameter though
	[Parameter(Mandatory=$false, ValueFromPipeLineByPropertyName=$true,ValueFromPipeLine=$true)]
	$skiplist=@(""), #force it into array
	[Parameter(Mandatory=$false, ValueFromPipeLineByPropertyName=$true,ValueFromPipeLine=$true)]
	$explicitUNClist=@(), #force it into array
	#example -- better to pass this in as parameter when calling script though:
	#$explicitUNClist=@("\\nycwinfs03\pubdocs\A","\\contoso.com\dfsfoo\A"), #force it into array
	[Parameter(Mandatory=$false, ValueFromPipeLineByPropertyName=$true,ValueFromPipeLine=$true)]
	[bool]$IncludeHiddenShares=$True,	#scan HiddenShares$ / Requires to be ran from Win7+ Server 2008+ or auto downgrades
	[Parameter(Mandatory=$false, ValueFromPipeLineByPropertyName=$true,ValueFromPipeLine=$true)]
	[string]$EmailSMTP="smtp.contoso.com",	# SMTP Server
	[Parameter(Mandatory=$false, ValueFromPipeLineByPropertyName=$true,ValueFromPipeLine=$true)]
	[string]$EmailTo="helpdesk@salvustg.com",	# E-mail Send to (e.g., SharePoint List receive e-mail)
	[Parameter(Mandatory=$false, ValueFromPipeLineByPropertyName=$true,ValueFromPipeLine=$true)]
	[string]$EmailFrom="cryptscan@salvustg.com",	# E-mail "from"
	[Parameter(Mandatory=$false, ValueFromPipeLineByPropertyName=$true,ValueFromPipeLine=$true)]
	[string]$EmailSubject="Cryptowall Scanner - Files Found",	# E-mail Subject 
	[Parameter(Mandatory=$false, ValueFromPipeLineByPropertyName=$true,ValueFromPipeLine=$true)]
	[bool]$useSystemScope=$True	# Use System Scope (HKLM vs HKCU) for storing prior cryptoscans to suppress prior finds; keep HKLM unless permissions do not allow
	
	)
	


BEGIN

 {
    
	#$DebugPreference="Continue" #comment to hide debugging
	$DebugPreference="SilentlyContinue" # default, enable when not debugging.

	#If you have multiple share names assigned to same actual back-end storage, you can eliminate the secondary/third/etc., by manually adding the paths here to skip them.
	$checkfiles=@("*INSTALL_TOR.URL","*HOW_DECRYPT.HTML","*HOW_DECRYPT.TXT","*HOW_DECRYPT.URL","*DECRYPT_INSTRUCTION.HTML","*DECRYPT_INSTRUCTION.TXT")
		#INSTALL_TOR.URL skipped for expediency but can be added later.
	$RunspaceCount=10 #how many runspaces to launch

	$sharename=""
	$fullUNC=""
	$UNCList=@()
	$Shares=""
	$PriorAlertList=@()
	$FirstAlert=$False
	$PriorAlertList=$null
	$PriorAlertCount=0
	$RegPath=""
    $Results = @()
    $FailedScan = New-Object System.Collections.ArrayList
    $Failed = $false
    $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    #$sessionState.ImportPSModule("PSThreading")
    $sessionstate.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry('FailedScan',$FailedScan,$null)))
    
    

	#Iter loop vars in actual job processing:
	$CurrentJobNumber=0
	$BaseCount=0
	$Iter=0
	$RunspacePool = [RunspaceFactory]::CreateRunspacePool(1, $RunspaceCount, $sessionState, $Host)
	$RunspacePool.Open()
    
	$Jobs = @()
	
	if ([environment]::OSversion.Version.Major -lt 6) { 
		$IncludeHiddenShares = $False 
	}

	if ($useSystemScope) {
		$RegPath="HKLM:\Software\CryptScan\Found"
		} 
    else {
		$RegPath="HKCU:\Software\CryptScan\Found"	
	}

		
	if ($PSVersionTable.PSVersion.major -lt 2) {
		Write-Warning "This script uses Runspaces that are unavailable in PowerShell 1.0, please upgrade to a newer version."
		return;	    
	} 
    elseif ($PSVersionTable.PSVersion.major -eq 2) {
		Write-Warning "This script is optimized for Powershell 4, it will work in 2 but recursions return all files and filter after, therefore it is potentially slower."
	}

} #end BEGIN

PROCESS {

if ($explicitUNClist.count -gt 0) {
	foreach ($share in $explicitUNClist) {
		write-debug ("Marking Explicit Share to scan: " + $share )
		$UNCList+=$share	
	}
}
$CheckCryptScriptBlock = {

   Param (
      $path,
	  $RegPath,
	  $useSystemScope,
	  $CheckFiles,
	  $EmailSMTP,
	  $EmailTo,
	  $EmailFrom,
	  $EmailSubject,
	  $IncludeHiddenShares,
      $FailedScan
   )

	$fileslist=@()
	$FirstAlert=$false
	
	if ($host.version.major -gt 2) {
		#PoSh 4, ignore instead silentlycontinue
		$mypath=$path + "\*DECRYPT*"
		$fileslist=@(get-childitem -path $mypath -Recurse -ErrorAction Ignore)
		
	} 
    else {
		#PoSh 2 doesn't have ignore and recurse works differently with wildcards, therefore returns all files and is much, much slower than posh4
		$mypath=$path + "\*"
		$fileslist=@(get-childitem -path $mypath -Recurse -ErrorAction SilentlyContinue)
	}
	#("$mypath fileslist count is " + $fileslist.count) >> c:\cryptodebug.txt
	$FirstAlertFiles=@()
    foreach ($item in $fileslist)  {
	
        if ($checkfiles | Where {$item.FullName -like $_}) { 
		
		#rebuild the prioralertlist in case of another multi-tasked task adding to it since.
		$PriorAlertList=@(Get-Item $RegPath -ErrorAction SilentlyContinue | Select-Object -ExpandProperty property | ForEach-Object { (Get-ItemProperty -Path $RegPath -Name $_).$_ })
		$PriorAlertCount=0 + $PriorAlertList.count

			#check if already previously alerted this file.
			if ($PriorAlertList | Where {$item.Fullname -like $_}) {
				#Already alerted. Do nothing.
				#"`n`nPrior cryptowall file found! $_ $($_.Fullname)"
			Write-Output "Prior cryptowall file found! $_ $($item.Fullname)`n" >> c:\cryptoresults.txt

			} else {
				#New File found
				if ($FirstAlert) {
					#Found a secondary/third file/etc in same share.
					"New cryptowall file found! $_ $($item.Fullname) $(Get-date)" >> c:\cryptoresults.txt
					$FirstAlertFiles+=$item
					} else {
					#First file found in share.
					Write-Debug "`n`n`nNew cryptowall file found! $_ $($item.Fullname) $(Get-Date)"
					"New cryptowall file found! $_ $($item.Fullname) $(Get-date)`n" >> c:\cryptoresults.txt
					$FirstAlertFiles+=$item
					}
				#add to list for end.
				$FirstAlert=$True
		
				#add log item to registry as well.
				if ($useSystemScope) {
				new-item -path "HKLM:\Software" -name CryptScan -erroraction silentlycontinue 2> $null
				new-item -path "HKLM:\Software\CryptScan" -name Found -erroraction silentlycontinue 2> $null
				} 
                else {
				new-item -path "HKCU:\Software" -name CryptScan -erroraction silentlycontinue 2> $null
				new-item -path "HKCU:\Software\CryptScan" -name Found -erroraction silentlycontinue 2> $null
				}

			} #if/else in the prior alert list
		 
		} #if matching $checkfiles item found
  
    } #end foreach file found
	
	if ($FirstAlert) {
        
			$MessageBody="Cryptowall Files Found `n"
			foreach ($filefound in $FirstAlertFiles) {
				$PriorAlertCount=1+$PriorAlertCount
				 $objFound = New-Object -TypeName PSObject -Property @{
                    Location  = $($filefound.fullname)
                    Owner = (get-acl $($filefound.fullname) -erroraction ignore).owner
                    LastModified = (get-item $($filefound.fullname) -erroraction ignore).lastwritetime
                }
				$MessageBody+="`n $($objFound.Location) `nOWNER: $($objFound.Owner) `nDateModified: $($objFound.LastModified)`n`n"
				#add new registry to save priors
				Set-ItemProperty -path $RegPath -name "CryptowallFound$PriorAlertCount" -value $($filefound.fullname)
                $FailedScan += $($filefound.fullname)
			}
			$MessageBody+="`n`n Running as $($env:USERNAME)  $(Get-Date -format G)"
			# send-mailmessage -from "$EmailFrom" -to "$EmailTo" -subject "$EmailSubject" -BodyASHTML $MessageBody -smtpServer "$EmailSMTP"
            Write-EventLog -LogName Application -Source CryptScan -EntryType Error -EventId 2319 -Message $MessageBody
		 #End FirstAlert Set
         return 2319
        
        }
     
} #End CheckCryptScriptBlock

if ($ComputerName.name) {
	#being piped in as object
	$ComputerName=$ComputerName.name
}

#Compile the $UNCList of all shares
foreach ($server in $ComputerName) {
	#Write-Debug "Current system is $server"
#net view for robustness; you could use WMI to get shares if you knew this was a windows system; 
#this will work with netapp and other major storage systems using standard CIFS/SMB
#2> $null redirects any error (such as error 53 for non-system) to null
	$Shares=@()
	write-debug ("Include Hidden is set to: " + $IncludeHiddenShares)
	if ($IncludeHiddenShares) {
		Write-Debug "Calling on all, including hidden"
		$Shares=@(Get-WmiObject -Class Win32_Share -ComputerName $server) 2> $null
	} else {
	Write-Debug ("Calling on all, not including hidden")
		$Shares=@(Get-WmiObject -Class Win32_Share -ComputerName $server | Where-Object {($_.Type -eq 0)}) 2> $null
	}

	if ($Shares.count -gt 4) {
		#0 count would be error; 2 is no shares on system
		#find where "Type" is within $shares[4] line - this is the offset for "Disk" column - varies by server /share length
		#parse out share name, and also type should not be print it should be Disk
		foreach ($share in $Shares) {
			$ValidShare=$False
			$fullUNC=""
			#parse it.			
			if (($share.Type -eq 0) -or ($share.Type -eq 2147483648)){
				$fullUNC="\\" + $server + "\" + $share.name
				foreach ($SkipUNC in $skiplist) {
					if ($SkipUNC -eq $fullUNC) {
						#Skip it. 
						$ValidShare=$False
						Write-Debug "Skipping $SkipUNC because it's in duplicate skip list - ValidShare set to $ValidShare"
						break
					} else {
						$ValidShare=$True
					}
				} #foreach item in $Skiplist
			} #end if share is disk (not printer/IPC/etc.)
			If ($ValidShare -eq $True) {
				write-debug ("Marking Share to scan: " + $fullUNC )
				$UNCList+=$fullUNC	
			}
		} #foreach share in $shares on a given system
	} #end if net View returned any valid shares
} #foreach server in computername array

<#
We now have the UNC List built;\
Go through UNClist by first adding explicit UNC items to scan in the order they were called
then by adding computernames and all underlying UNC paths, stepping through the UNC list 
seperated by # of runspaces to split things up 
e.g., 1, 10, 20, 30, 40, 2, 12, 22, 32, 3, 13, 23, 33, 4, etc... if runspaces value is 10 threads at a time
#>
#write-debug ("UNCList count is " + $UNCList.Count)
while ($Iter -lt $($UNCList.Count)) {
		Write-Debug "Calling checkcrypt on $($UNCList[$CurrentJobNumber])"
        Write-Debug "CurrentJobNumber is $CurrentJobNumber"
        Write-Debug "Iter is $Iter"
        Write-Debug "Count is $($UNCList.Count)"
	    
	    #$Job = [powershell]::Create().AddScript($CheckCryptScriptBlock).AddArgument($UNCList[$CurrentJobNumber]).AddArgument($RegPath).AddArgument($useSystemScope).AddArgument($CheckFiles).AddArgument($EmailSMTP).AddArgument($EmailTo).AddArgument($EmailFrom).AddArgument($EmailSubject).AddArgument($IncludeHiddenShares).AddArgument($FailedScanScan)
	    $Job = [powershell]::Create().AddScript($CheckCryptScriptBlock).AddArgument($UNCList[$CurrentJobNumber]).AddArgument($RegPath).AddArgument($useSystemScope).AddArgument($CheckFiles).AddArgument($IncludeHiddenShares).AddArgument($FailedScan)
    	$Job.RunspacePool = $RunspacePool
   		$Jobs += New-Object PSObject -Property @{
   			RunNum = $Iter
			Pipe = $Job
			Result = $Job.BeginInvoke()
	  	}

	$Iter+=1
	if (($explicitUNClist.count -gt 0) -and ($Iter -lt $explicitUNClist.count)) {
		#cover the explicit list first before moving on to semi-randomizing the computername unc list, use basecount as the marker for the end of this list in whichloop
			$BaseCount+=1
			$CurrentJobNumber=$BaseCount
	} else {
		#all Explicit UNC paths already added and basecount now after it in array.
		#check if adding value for $runspacecount (10) to current position sets us over total count and if so go back to base+1
		if (($CurrentJobNumber+$RunspaceCount) -lt $($UNCList.Count)) {
			$CurrentJobNumber=$CurrentJobNumber+$RunspaceCount
		} else {
			$BaseCount+=1
			$CurrentJobNumber=$BaseCount
		} #if/else new currentjob would exceed total count
	} #end if explicitlist is fully processed
    
}
} #END Process

END {
	#Display counter of paths remaining to scan while the processing is ongoing in runspaces
	
	$NotFinished=$true
	$incomplete=0
	Write-Verbose "$($Jobs.Count) jobs started.."
	Do {
	  	Start-Sleep -Seconds 1
		#reusing $incomplete variable for the loop of every 10 seconds then once that triggers, within the foreach loop of jobs	 
		if ($incomplete -gt 10) {
		 	#give count every 10 seconds
		 	$incomplete=0
		 	foreach ($Job in $Jobs) {
		 		if ($Job.Result.IsCompleted -contains $False) {
					$incomplete+=1
		 		}
                else {
               
                    
                    
                }
                    
			}
			if ($incomplete -gt 0) {
				write-verbose " Remaining Paths to scan: $incomplete "
				$incomplete=0
			} else { 
				#we are all finished with every scan. All jobs complete.
				$NotFinished=$false	
                foreach($job in $jobs) {
                #Write-Output $Job.Pipe.Endinvoke($Job.Result)
                if ($Job.Pipe.EndInvoke($Job.Result) -eq 2319) { $Failed = $true }
                $job.Pipe.Dispose()
                Write-Output "$($Job.RunNum) completed"

                }
      		}
		} else {
			$incomplete+=1
		} #end if incomplete gt 10
	} While ($NotFinished)
    if ($Failed) { 
        Write-Output "CryptoWall files found. See Event Viewer for paths and ownership"
        Write-Output (Get-Content C:\cryptoresults.txt)
        exit 2319
     }
    else { 
        Write-Output "Scan complete. No new files detected"
        Write-Output "Prior files:"
        Write-Output (Get-Item $RegPath -ErrorAction SilentlyContinue | Select-Object -ExpandProperty property | ForEach-Object { (Get-ItemProperty -Path $RegPath -Name $_).$_ })
        exit 0
    }

} #End END statement
