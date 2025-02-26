Add-Type -AssemblyName System.Drawing

$inputFile = "assets\icon.jpg"
$outputFile = "assets\icon.ico"

# Load the image
$image = [System.Drawing.Image]::FromFile((Resolve-Path $inputFile))

# Save as icon
$bitmap = New-Object System.Drawing.Bitmap($image)
$icon = [System.Drawing.Icon]::FromHandle($bitmap.GetHIcon())

# Create FileStream
$stream = [System.IO.File]::Create((Resolve-Path -Path "." | Join-Path -ChildPath $outputFile))

# Save the icon
$icon.Save($stream)

# Clean up
$stream.Close()
$icon.Dispose()
$bitmap.Dispose()
$image.Dispose() 