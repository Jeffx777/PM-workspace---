Param(
    [Parameter(Mandatory=$true)]
    [string]$InputFile,
    
    [string]$Suffix = "_portable"
)

# 确保输入文件存在
if (-not (Test-Path $InputFile)) {
    Write-Error "找不到输入文件: $InputFile"
    exit 1
}

$inputFileFull = Get-Item $InputFile
$workingDir = $inputFileFull.DirectoryName
$fileNameNoExt = [System.IO.Path]::GetFileNameWithoutExtension($inputFileFull.Name)
$extension = $inputFileFull.Extension
$outputFile = Join-Path $workingDir "$fileNameNoExt$Suffix$extension"

Write-Host "正在处理: $($inputFileFull.Name)" -ForegroundColor Cyan

# 读取内容
$html = Get-Content -Path $inputFileFull.FullName -Raw -Encoding UTF8

# 正则匹配 src 属性
# 支持 src="assets/..." 或 src="./assets/..."
$regex = 'src="(?:\./)?([^"]+\.(?:jpg|jpeg|png|webp|gif))"'
$matches = [regex]::Matches($html, $regex)

$count = 0
foreach ($match in $matches) {
    $relativePath = $match.Groups[1].Value
    $fullImagePath = Join-Path $workingDir $relativePath
    
    if (Test-Path $fullImagePath) {
        $bytes = [System.IO.File]::ReadAllBytes($fullImagePath)
        $base64 = [System.Convert]::ToBase64String($bytes)
        
        $imgExt = [System.IO.Path]::GetExtension($fullImagePath).TrimStart('.').ToLower()
        if ($imgExt -eq "jpg") { $imgExt = "jpeg" }
        
        $dataUri = "src=`"data:image/$imgExt;base64,$base64`""
        $html = $html.Replace($match.Value, $dataUri)
        $count++
    } else {
        Write-Warning "跳过缺失文件: $relativePath"
    }
}

# 写入新文件
$html | Set-Content -Path $outputFile -Encoding UTF8

Write-Host "成功生成便携版: $outputFile" -ForegroundColor Green
Write-Host "共嵌入 $count 张图片。" -ForegroundColor Gray
