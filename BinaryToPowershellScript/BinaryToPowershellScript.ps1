function BinaryToPowershellScript {
	[CmdletBinding()]
	param(
		[Parameter(Mandatory=$true)]  [Alias('i')] [String[]] $Inputs,
		[Parameter(Mandatory=$false)] [Alias('o')] [String] $OutputFolder,
		[Parameter(Mandatory=$false)] [Alias('b')] [switch] $Base64=$false,
		[Parameter(Mandatory=$false)] [Alias('d')] [switch] $Decimal=$false,
		[Parameter(Mandatory=$false)] [Alias('h')] [switch] $Hash=$false,
		[Parameter(Mandatory=$false)] [Alias('s')] [switch] $SingleFile=$false,
		[Parameter(Mandatory=$false)] [Alias('r')] [switch] $Recurse=$false,
		[Parameter(Mandatory=$false)] [Alias('c')] [switch] $Compress=$false,
		[Parameter(Mandatory=$false)] [Alias('p')] [String] $Password
	)

	$global:KEYSIZE = 256

	[System.IO.Directory]::SetCurrentDirectory((Convert-Path (Get-Location).Path))

	if ([System.String]::IsNullOrEmpty($OutputFolder)) {
		$OutputFolder = '.'
	}

	$script = CreateScriptHeader $Password

	$outputFile = [System.IO.Path]::Combine($OutputFolder,"SingleScript$(TernaryExpression $Base64 "_base64" '').ps1")
	foreach ($inputFile in $Inputs)
	{
		$path = ([System.IO.Path]::GetDirectoryName($inputFile))

		if (![System.String]::IsNullOrEmpty($path) -and !($path -eq ".")) {
			$path = (Resolve-Path -Relative (Convert-Path $path))
		}
		else {
			$path = "."
		}

		$path

		foreach ($file in [System.IO.Directory]::GetFiles($path, [System.IO.Path]::GetFileName($inputFile), (TernaryExpression $Recurse ([System.IO.SearchOption] 'AllDirectories') ([System.IO.SearchOption] 'TopDirectoryOnly'))))
		{
			if (!$singlefile)
			{
				$script = CreateScriptHeader $password
				$outputfile = [System.IO.Path]::Combine($outputfolder,"$([System.IO.Path]::GetFileName($file).replace(".", "_"))_script$(ternaryexpression $base64 "_base64" '').ps1")
			}
			$additionalText = TernaryExpression (!$SingleFile) "into $outputFile..." ''
			Write-Host -NoNewline "Scripting file $file $additionalText"

			$inputFileBytes = [System.IO.File]::ReadAllBytes($file)
			$hashParameter = TernaryExpression $Hash "`'$(ComputeSha256Hash($inputFileBytes))`'" ''

			if ($Compress) {
				$compressedFileBytes = copyBytesToStream $inputFileBytes $false { param ($EncryptedStream) New-Object System.IO.Compression.DeflateStream($EncryptedStream, [System.IO.Compression.CompressionMode] 'Compress') } 

				if ($compressedFileBytes.Length -lt $inputFileBytes.Length) {
					$inputFileBytes = $compressedFileBytes
					$ActualCompress=$true
				}
				else {
					Write-Host -NoNewline "compression useless, disabling it..."
					$ActualCompress=$false
				}
			}

 			[byte[]] $bytes = TernaryExpression ([System.String]::IsNullOrEmpty($Password)) $inputFileBytes (EncryptBytes $inputFileBytes  $Password)
			if ($Base64)
			{
				$b64 = [System.Convert]::ToBase64String($bytes)
				[void] $script.Append("`t[byte[]] `$bytes = [System.Convert]::FromBase64String(`'$b64`')")
			}
			else
			{
				[void] $script.Append("`t[byte[]] `$bytes = ")
				foreach ($b in $bytes)
				{
					if ($Decimal)
					{
						[void] $script.Append("$($b.ToString('D')),")
					}
					else
					{
						[void] $script.Append("0x$($b.ToString('X2')),")
					}
				}
				[void] ($script.Length--)
			}

			[void] $script.Append("`n`tcreateFile `'$file`' `$bytes `$password $hashParameter `$$ActualCompress`n`n")
			if (!$SingleFile) {
				[void] $script.Append("`}`n`ncreateFiles `'$Password`'`n")

				$outputScript = $script.ToString()
				[System.IO.File]::WriteAllText($outputFile,$outputScript)
				Write-Host "length $([Math]::Round($outputScript.Length/1024))KB."
			}
			else {
				Write-Host "`n"
			}
		}
	}
	if ($SingleFile)
	{
		[void] $script.Append("`}`n`ncreateFiles `'$Password`'`n")

		$outputScript = $script.ToString()
		[System.IO.File]::WriteAllText($outputFile,$outputScript)
		Write-Host "Created single script file $outputFile length $([Math]::Round($outputScript.Length/1024))KB."
	}
}


function copyBytesToStream  {
	[OutputType([byte[]])]
	Param (
		[Parameter(Mandatory=$true)] [byte[]] $bytes,
		[Parameter(Mandatory=$true)] [System.Boolean] $fromStream,
		[Parameter(Mandatory=$true)] [ScriptBlock] $streamCallback)

	$InputMemoryStream = New-Object System.IO.MemoryStream @(,$bytes)
	$OutputMemoryStream = New-Object System.IO.MemoryStream

	$stream = (Invoke-Command $streamCallback -ArgumentList (TernaryExpression $fromStream $InputMemoryStream $OutputMemoryStream))

	if ($fromStream) {
		$stream.CopyTo($OutputMemoryStream)
	}
	else {
		$InputMemoryStream.CopyTo($stream)
		$stream.Flush()
	}

	$result = $OutputMemoryStream.ToArray()

	,$result
}




function TernaryExpression {
    Param (
		[Parameter(Mandatory=$true)] [System.Boolean] $booleanExpression,
		[Parameter(Mandatory=$false)] $TrueExpression,
		[Parameter(Mandatory=$false)] $FalseExpression
	)

	if ($booleanExpression) {
		,$TrueExpression
	}
	else {
		,$FalseExpression
	}
}


function ComputeSha256Hash
{
	[OutputType([string])]
	param ([Parameter(Mandatory=$true)] [byte[]] $bytes)
	[System.Security.Cryptography.SHA256]$sha256Hash = $null
	try
	{
		$sha256Hash = [System.Security.Cryptography.SHA256]::Create()
		return [System.BitConverter]::ToString($sha256Hash.ComputeHash($bytes)).Replace("-",'')
	}
	finally
	{
		$sha256Hash.Dispose()
	}
}



function EncryptBytes
{
   [OutputType([byte[]])]
    Param (
		[Parameter(Mandatory=$true)] [System.Byte[]] $inputFile,
		[Parameter(Mandatory=$false)] [System.String] $password
	) 

	$pbkdf2DerivedBytes = (New-Object -TypeName System.Security.Cryptography.Rfc2898DeriveBytes -ArgumentList $password,16,2000)
	$AES = $null
	try
	{
		$AES = [System.Security.Cryptography.Aes]::Create()
		$AES.KeySize = $global:KEYSIZE
		$AES.Key = $pbkdf2DerivedBytes.GetBytes($global:KEYSIZE/8)
		$AES.Mode = [System.Security.Cryptography.CipherMode]::CBC
		$AES.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
		[System.IO.MemoryStream]$memoryStream = $null
		try
		{
			$memoryStream = (New-Object -TypeName System.IO.MemoryStream)
			[System.Security.Cryptography.CryptoStream]$cryptoStream = (New-Object -TypeName System.Security.Cryptography.CryptoStream -ArgumentList $memoryStream,$AES.CreateEncryptor(),([System.Security.Cryptography.CryptoStreamMode] 'Write'))
			$memoryStream.Write($pbkdf2DerivedBytes.Salt,0,16)
			$memoryStream.Write($AES.IV,0,16)
			$cryptoStream.Write($inputFile,0,$inputFile.Length)
			$cryptoStream.FlushFinalBlock()
			return ,$memoryStream.ToArray()
		}
		finally
		{
			$memoryStream.Dispose()
		}
	}
	finally
	{
		$AES.Dispose()
	}
}



function CreateScriptHeader
{
	[OutputType([System.Text.StringBuilder])]
    Param (
		[Parameter(Mandatory=$false)] [System.String] $Password
	) 

	$sb = (New-Object -TypeName System.Text.StringBuilder)

	[void] $sb.AppendLine(@"
function passBytesThroughStream  `{
`t[OutputType([byte[]])]
`tParam (
`t`t[Parameter(Mandatory=`$true)] [byte[]] `$bytes,
`t`t[Parameter(Mandatory=`$true)] [ScriptBlock] `$streamCallback)

`t`$InputMemoryStream = New-Object System.IO.MemoryStream @(,`$bytes)
`t`$OutputMemoryStream = New-Object System.IO.MemoryStream

`t`$stream = (Invoke-Command `$streamCallback -ArgumentList `$InputMemoryStream)

`t`$stream.CopyTo(`$OutputMemoryStream)

`t`$result = `$OutputMemoryStream.ToArray()

`t,`$result
`}

"@);


	if (![System.String]::IsNullOrEmpty($Password))
	{
		        # uncomment these lines and put them in the decryptBytes function below (row "$Dec = $AES.CreateDecryptor()") to troubleshoot encryption
                #Write-Host ''Password $password''
                #Write-Host ''KEY: $([System.BitConverter]::ToString($AES.Key))''
                #Write-Host ''IV: $([System.BitConverter]::ToString($AES.IV))''
                #Write-Host ''EncryptedData: $([System.BitConverter]::ToString($EncryptedData))''

                # uncomment these lines and put them in the decryptBytes function below (row ",$result") to troubleshoot encryption
                #Write-Host ''DecryptedData: $([System.BitConverter]::ToString($result))''

                [void] $sb.AppendLine(@"
function decryptBytes `{
`t[OutputType([byte[]])]
`tParam (
`t`t[Parameter(Mandatory=`$true)] [System.Byte[]] `$bytes,
`t`t[Parameter(Mandatory=`$true)] [System.String] `$password
`t) 

`t# Split IV and encrypted data
`t`$PBKDF2Salt = New-Object Byte[] 16
`t`$IV = New-Object Byte[] 16
`t`$EncryptedData = New-Object Byte[] (`$bytes.Length-32)
    
`t[System.Array]::Copy(`$bytes, 0, `$PBKDF2Salt, 0, 16)
`t[System.Array]::Copy(`$bytes, 16, `$IV, 0, 16)
`t[System.Array]::Copy(`$bytes, 32, `$EncryptedData, 0, `$bytes.Length-32)

`t# Generate PBKDF2 from Salt and Password
`t`$PBKDF2 = New-Object System.Security.Cryptography.Rfc2898DeriveBytes(`$password, `$PBKDF2Salt, 2000)

`t# Setup our decryptor
`t`$AES = [Security.Cryptography.Aes]::Create()
`t`$AES.KeySize = $global:KEYSIZE
`t`$AES.Key = `$PBKDF2.GetBytes($($global:KEYSIZE/8))
`t`$AES.IV = `$IV
`t`$AES.Mode = [System.Security.Cryptography.CipherMode]::CBC
`t`$AES.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7

`t`$Dec = `$AES.CreateDecryptor()

`t[byte[]] `$result = passBytesThroughStream `$EncryptedData { param (`$EncryptedStream) New-Object System.Security.Cryptography.CryptoStream(`$EncryptedStream, `$Dec, [System.Security.Cryptography.CryptoStreamMode] `'Read`') } 

`t,`$result
`}

"@)
	}

	$decryptBytes = TernaryExpression ([System.String]::IsNullOrEmpty($Password)) '' "`$bytes = `$(decryptBytes `$bytes `$password)"

	[void] $sb.AppendLine(@"
function createFile  `{
`tparam (
`t`t[Parameter(Mandatory=`$true)] [String] `$file,
`t`t[Parameter(Mandatory=`$true)] [byte[]] `$bytes,
`t`t[Parameter(Mandatory=`$false)] [String] `$password,
`t`t[Parameter(Mandatory=`$false)] [String] `$hash,
`t`t[Parameter(Mandatory=`$false)] [System.Boolean] `$decompress=`$false)
	
`t`$null = New-Item -ItemType Directory -Path (Split-Path `$file) -Force
`t$decryptBytes

`tif (`$decompress) {
`t`t`$bytes = passBytesThroughStream `$bytes { param (`$EncryptedStream) New-Object System.IO.Compression.DeflateStream(`$EncryptedStream, [System.IO.Compression.CompressionMode ] `'Decompress`') } 
`t}

`tif (`$global:core) `{ Set-Content -Path `$file -Value `$bytes -AsByteStream -Force `} else `{ Set-Content -Path `$file -Value `$bytes -Encoding Byte -Force `}

`tif (![System.String]::IsNullOrEmpty(`$hash)) `{
`t`t`$actualHash = (Get-FileHash -Path `$file -Algorithm Sha256).Hash
`t`tif (`$actualHash -ne `$hash) `{
`t`t`tWrite-Error "Integrity check failed on `$file expected `$hash actual `$actualHash!"
`t`t`}
`t`}

`tWrite-Host "Created file `$file Length `$(`$bytes.Length)"
`}

"@)
	[void] $sb.Append("function createFiles  `{`n`tparam ([Parameter(Mandatory=$(TernaryExpression ([System.String]::IsNullOrEmpty($Password)) "`$false" "`$true"))] [String] `$password)`n`n")
	[void] $sb.Append("`t`$setContentHelp = (help Set-Content) | Out-String`n`tif (`$setContentHelp.Contains('AsByteStream')) { `$global:core = `$true } else { `$global:core = `$false }`n`n")
	,$sb
}
