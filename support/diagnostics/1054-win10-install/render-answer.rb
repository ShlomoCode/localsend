require 'securerandom'
require 'cgi'
# An ephemeral account password exists only in private media and the guest disk.
# Neither is uploaded. Do not print XML, seed media, or the generated password.
password = CGI.escapeHTML(SecureRandom.hex(20) + 'Az9!')
component = 'processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS"'
command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \"Get-PSDrive -PSProvider FileSystem | ForEach-Object { $p=Join-Path $_.Root 'Bootstrap.ps1'; if(Test-Path $p){ &amp; $p } }\""
File.write(ARGV.fetch(0), <<~XML)
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
  <settings pass="windowsPE">
    <component name="Microsoft-Windows-International-Core-WinPE" #{component}>
      <SetupUILanguage><UILanguage>en-US</UILanguage></SetupUILanguage>
      <InputLocale>0409:00000409</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale>
    </component>
    <component name="Microsoft-Windows-Setup" #{component}>
      <DiskConfiguration><Disk wcm:action="add"><DiskID>0</DiskID><WillWipeDisk>true</WillWipeDisk>
        <CreatePartitions><CreatePartition wcm:action="add"><Order>1</Order><Type>Primary</Type><Size>500</Size></CreatePartition><CreatePartition wcm:action="add"><Order>2</Order><Type>Primary</Type><Extend>true</Extend></CreatePartition></CreatePartitions>
        <ModifyPartitions><ModifyPartition wcm:action="add"><Order>1</Order><PartitionID>1</PartitionID><Active>true</Active><Format>NTFS</Format><Label>System</Label></ModifyPartition><ModifyPartition wcm:action="add"><Order>2</Order><PartitionID>2</PartitionID><Format>NTFS</Format><Label>Windows</Label><Letter>C</Letter></ModifyPartition></ModifyPartitions>
      </Disk><WillShowUI>OnError</WillShowUI></DiskConfiguration>
      <ImageInstall><OSImage><InstallFrom><MetaData wcm:action="add"><Key>/IMAGE/INDEX</Key><Value>1</Value></MetaData></InstallFrom><InstallTo><DiskID>0</DiskID><PartitionID>2</PartitionID></InstallTo><WillShowUI>OnError</WillShowUI></OSImage></ImageInstall>
      <UserData><AcceptEula>true</AcceptEula><FullName>LocalSend diagnostic</FullName><Organization>Diagnostic</Organization></UserData>
    </component>
  </settings>
  <settings pass="specialize"><component name="Microsoft-Windows-Shell-Setup" #{component}><ComputerName>Sender</ComputerName><TimeZone>UTC</TimeZone></component></settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-International-Core" #{component}><InputLocale>0409:00000409</InputLocale><SystemLocale>en-US</SystemLocale><UILanguage>en-US</UILanguage><UserLocale>en-US</UserLocale></component>
    <component name="Microsoft-Windows-Shell-Setup" #{component}>
      <OOBE><HideEULAPage>true</HideEULAPage><HideOEMRegistrationScreen>true</HideOEMRegistrationScreen><HideOnlineAccountScreens>true</HideOnlineAccountScreens><ProtectYourPC>3</ProtectYourPC></OOBE>
      <UserAccounts><LocalAccounts><LocalAccount wcm:action="add"><Name>Probe</Name><DisplayName>Probe</DisplayName><Group>Administrators</Group><Password><Value>#{password}</Value><PlainText>true</PlainText></Password></LocalAccount></LocalAccounts></UserAccounts>
      <AutoLogon><Enabled>true</Enabled><Username>Probe</Username><LogonCount>1</LogonCount><Password><Value>#{password}</Value><PlainText>true</PlainText></Password></AutoLogon>
      <FirstLogonCommands><SynchronousCommand wcm:action="add"><Order>1</Order><Description>Record valid evaluation and launch official app</Description><CommandLine>#{command}</CommandLine></SynchronousCommand></FirstLogonCommands>
    </component>
  </settings>
</unattend>
XML
File.chmod(0600, ARGV.fetch(0))
