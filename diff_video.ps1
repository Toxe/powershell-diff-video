# & .\diff_video.ps1 video1 video2 output.mp4

$PSStyle.Progress.View = 'Classic'

function WithDuration {
    param (
        [string]$label,
        [ScriptBlock]$command
    )

    process {
        Write-Host $label
        $t = Get-Date

        & $command

        Write-Host ('--> {0:n3} seconds' -f (((Get-Date) - $t).TotalSeconds))
        Write-Host ''
    }
}

function WithProgress {
    param (
        [Parameter(ValueFromPipeline)] $input,
        [Parameter(Mandatory)] [string]$Activity,
        [Parameter(Mandatory)] [int]$MaxCounter,
        [string]$StatusText = 'completed',
        [ScriptBlock]$Begin = { },
        [ScriptBlock]$Process = { },
        [ScriptBlock]$End = { },
        [ScriptBlock]$PercentComplete = { [math]::Round(100.0 * $counter / $MaxCounter) },
        [ScriptBlock]$UpdateCounter = { $counter + 1 }
    )

    begin {
        $counter = 0

        & $Begin

        $percent = & $PercentComplete
        $status = '{0}/{1} {2} ({3}%)' -f $counter, $MaxCounter, $StatusText, $percent
        Write-Progress -Activity $Activity -Status $status -PercentComplete $percent
    }

    process {
        $counter = & $UpdateCounter

        & $Process $input

        $percent = & $PercentComplete
        $status = '{0}/{1} {2} ({3}%)' -f $counter, $MaxCounter, $StatusText, $percent
        Write-Progress -Activity $Activity -Status $status -PercentComplete $percent
    }

    end {
        & $End
        Write-Progress -Activity $Activity -Completed
    }
}

function Die {
    param (
        [int]$exitcode,
        [string]$message
    )

    Write-Error "Error: $message"
    Exit $exitcode
}

function AddPostfixToFilename {
    param (
        [string]$filename,
        [string]$postfix
    )

    $dir = [System.IO.Path]::GetDirectoryName($filename)
    $basename = [System.IO.Path]::GetFileNameWithoutExtension($filename)
    $extension = [System.IO.Path]::GetExtension($filename)
    return [System.IO.Path]::Combine($dir, '{0}_{1}{2}' -f ($basename, $postfix, $extension))
}

function BuildFramesFilenameTemplate {
    param (
        [string]$dir,
        [string]$postfix
    )

    return '{0}\%06d_{1}.png' -f ($dir, $postfix)
}

function BuildFrameBasename {
    param (
        [string]$postfix,
        [int]$id
    )

    return '{0:d6}_{1}.png' -f ($id, $postfix)
}

function BuildFrameFullPath {
    param (
        [string]$dir,
        [string]$postfix,
        [int]$id
    )

    return Join-Path -Path "$dir" -ChildPath (& BuildFrameBasename $postfix $id)
}

function EvalArgs {
    param (
        [array]$params
    )

    if ($params.Count -lt 3) { Die 1 'Missing arguments' }

    return $params[0], $params[1], $params[2], (AddPostfixToFilename $params[2] 'montage')
}

function GetNumberOfCoresAndThreads {
    $num_cores = ([Environment]::ProcessorCount)
    $imagick_threads = 2
    $ffmpeg_threads = [int]($num_cores / 2)
    Write-Host "CPU cores: $num_cores"
    Write-Host "ImageMagick threads: $imagick_threads"
    Write-Host "FFmpeg threads: $ffmpeg_threads"

    return $num_cores, $imagick_threads, $ffmpeg_threads
}

function InputVideoMustExist {
    param (
        [string]$video,
        [int]$id
    )

    if (-Not (Test-Path $video)) { Die 2 "Video $id not found: $video" }
    Write-Host "input video ${id}: $video"
}

function OutputVideoMustNotExist {
    param (
        [string]$video,
        [string]$desc
    )

    if (Test-Path $video) { Die 3 "Output video ($desc) already exists: $video" }
    Write-Host "output video ($desc): $video"
}

function CreateTempWorkDirectory {
    $temp_dir = [System.IO.Path]::GetTempPath()
    $random_name = [System.IO.Path]::GetRandomFileName()
    $work_dir = Join-Path -Path "$temp_dir" -ChildPath "$random_name"
    New-Item -Path "$work_dir" -ItemType Directory | Out-Null
    Write-Host "work directory: $work_dir"

    return $work_dir
}

function ExtractFrames {
    param (
        [string]$work_dir,
        [string]$video1,
        [string]$video2,
        [int]$ffmpeg_threads
    )

    Write-Host ''

    WithDuration 'extracting frames...' {
        $func_BuildFramesFilenameTemplate = ${function:BuildFramesFilenameTemplate}.ToString()

        $videos = @(
            @($video1, 'a'),
            @($video2, 'b')
        )

        $videos | ForEach-Object -Parallel {
            ${function:BuildFramesFilenameTemplate} = $using:func_BuildFramesFilenameTemplate

            $video = $_[0]
            $frames = BuildFramesFilenameTemplate "${using:work_dir}" $_[1]
            ffmpeg -v error -i "$video" -threads $using:ffmpeg_threads "$frames"
        }

        $video1_number_of_frames = (Get-ChildItem -Path "$work_dir" -Name -File -Filter *_a.png).Length
        $video2_number_of_frames = (Get-ChildItem -Path "$work_dir" -Name -File -Filter *_b.png).Length
        Write-Host "video 1 frames: $video1_number_of_frames"
        Write-Host "video 2 frames: $video2_number_of_frames"

        return $video1_number_of_frames
    }
}

function GenerateDiffs {
    param (
        [string]$work_dir,
        [int]$number_of_frames,
        [int]$num_cores,
        [int]$imagick_threads
    )

    WithDuration 'generating diffs...' {
        $func_BuildFrameBasename = ${function:BuildFrameBasename}.ToString()
        $func_BuildFrameFullPath = ${function:BuildFrameFullPath}.ToString()

        1..$number_of_frames | ForEach-Object -ThrottleLimit $num_cores -Parallel {
            ${function:BuildFrameBasename} = $using:func_BuildFrameBasename
            ${function:BuildFrameFullPath} = $using:func_BuildFrameFullPath

            $frame_a = BuildFrameFullPath "${using:work_dir}" 'a' $_
            $frame_b = BuildFrameFullPath "${using:work_dir}" 'b' $_
            $frame_d = BuildFrameFullPath "${using:work_dir}" 'd' $_
            magick -limit thread $using:imagick_threads "${frame_a}" "${frame_b}" -compose difference -composite -evaluate Pow 2 -evaluate divide 3 -separate -evaluate-sequence Add -evaluate Pow 0.5 "${frame_d}"
            $_
        } | WithProgress -Activity 'generating diffs...' -MaxCounter $number_of_frames
    }
}

function CalculateMinMaxIntensity {
    param (
        [string]$work_dir,
        [int]$number_of_frames,
        [int]$num_cores,
        [int]$imagick_threads
    )

    WithDuration 'calculating min/max intensity...' {
        $func_BuildFrameBasename = ${function:BuildFrameBasename}.ToString()
        $func_BuildFrameFullPath = ${function:BuildFrameFullPath}.ToString()

        $lines = 1..$number_of_frames | ForEach-Object -ThrottleLimit $num_cores -Parallel {
            ${function:BuildFrameBasename} = $using:func_BuildFrameBasename
            ${function:BuildFrameFullPath} = $using:func_BuildFrameFullPath

            $frame = BuildFrameFullPath "${using:work_dir}" 'd' $_
            $output = magick identify -limit thread $using:imagick_threads -format '%[min] %[max]\n' "${frame}"
            $output
        } | WithProgress -Activity 'calculating min/max intensity...' -MaxCounter $number_of_frames -Process { $_ }

        $min_intensity = [int]::MaxValue
        $max_intensity = [int]::MinValue

        $lines | ForEach-Object {
            $a, $b = $_ -split ' '
            $min_intensity = [math]::min($a, $min_intensity)
            $max_intensity = [math]::max($b, $max_intensity)
        }

        Write-Host "min intensity: $min_intensity"
        Write-Host "max intensity: $max_intensity"

        return $min_intensity, $max_intensity
    }
}

function NormalizeDiffs {
    param (
        [string]$work_dir,
        [int]$number_of_frames,
        [int]$num_cores,
        [int]$imagick_threads,
        [int]$min_intensity,
        [int]$max_intensity
    )

    WithDuration 'normalizing diffs...' {
        $func_BuildFrameBasename = ${function:BuildFrameBasename}.ToString()
        $func_BuildFrameFullPath = ${function:BuildFrameFullPath}.ToString()

        1..$number_of_frames | ForEach-Object -ThrottleLimit $num_cores -Parallel {
            ${function:BuildFrameBasename} = $using:func_BuildFrameBasename
            ${function:BuildFrameFullPath} = $using:func_BuildFrameFullPath

            $frame_d = BuildFrameFullPath "${using:work_dir}" 'd' $_
            $frame_n = BuildFrameFullPath "${using:work_dir}" 'n' $_
            magick -limit thread $using:imagick_threads "${frame_d}" -level "$using:min_intensity,$using:max_intensity" "${frame_n}"
            $_
        } | WithProgress -Activity 'normalizing diffs...' -MaxCounter $number_of_frames
    }
}

function RenderVideoDiff {
    param (
        [string]$work_dir,
        [string]$output_video_diff,
        [int]$number_of_frames
    )

    WithDuration 'rendering diff video...' {
        $frames_n = BuildFramesFilenameTemplate "$work_dir" 'n'

        ffmpeg -v error -nostats -hide_banner -progress pipe:1 -framerate 60000/1001 -i "$frames_n" -vf 'colorchannelmixer=.0:.0:.0:0:.0:1:.0:0:.0:.0:.0:0' -c:v libx264 -crf 18 -preset veryfast "$output_video_diff" |
            Where-Object { $_ -match 'frame=(\d+)' } |
            ForEach-Object { $Matches[1] } |
            WithProgress -Activity 'rendering diff video...' -MaxCounter $number_of_frames -StatusText 'frames' -UpdateCounter { $_ }
    }
}

function RenderVideoMontage {
    param (
        [string]$video1,
        [string]$video2,
        [string]$output_video_diff,
        [string]$output_video_montage,
        [int]$number_of_frames
    )

    WithDuration 'rendering montage video...' {
        ffmpeg -v error -nostats -hide_banner -progress pipe:1 -i "$video1" -i "$video2" -i "$output_video_diff" -filter_complex '[0:v][1:v]vstack[left]; [2:v]scale=iw:2*ih[right]; [left][right]hstack' -c:v libx264 -crf 18 -preset veryfast "$output_video_montage" |
            Where-Object { $_ -match 'frame=(\d+)' } |
            ForEach-Object { $Matches[1] } |
            WithProgress -Activity 'rendering montage video...' -MaxCounter $number_of_frames -StatusText 'frames' -UpdateCounter { $_ }
    }
}

function DeleteTempWorkDirectory {
    param (
        [string]$work_dir
    )

    WithDuration 'cleaning up...' {
        Remove-Item -Path "$work_dir" -Recurse
    }
}

$VIDEO1, $VIDEO2, $OUTPUT_VIDEO_DIFF, $OUTPUT_VIDEO_MONTAGE = EvalArgs $args
$num_cores, $imagick_threads, $ffmpeg_threads = GetNumberOfCoresAndThreads
InputVideoMustExist $VIDEO1 1
InputVideoMustExist $VIDEO2 2
OutputVideoMustNotExist $OUTPUT_VIDEO_DIFF 'diff'
OutputVideoMustNotExist $OUTPUT_VIDEO_MONTAGE 'montage'
$work_dir = CreateTempWorkDirectory

$number_of_frames = ExtractFrames $work_dir $VIDEO1 $VIDEO2 $ffmpeg_threads
GenerateDiffs $work_dir $number_of_frames $num_cores $imagick_threads
$min_intensity, $max_intensity = CalculateMinMaxIntensity $work_dir $number_of_frames $num_cores $imagick_threads
NormalizeDiffs $work_dir $number_of_frames $num_cores $imagick_threads $min_intensity $max_intensity
RenderVideoDiff $work_dir $OUTPUT_VIDEO_DIFF $number_of_frames
RenderVideoMontage $VIDEO1 $VIDEO2 $OUTPUT_VIDEO_DIFF $OUTPUT_VIDEO_MONTAGE $number_of_frames

DeleteTempWorkDirectory $work_dir
