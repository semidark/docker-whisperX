import sys
from pyannote.audio import Pipeline

# Get the token from command line argument
hf_token = sys.argv[1] if len(sys.argv) > 1 else ""

try:
    Pipeline.from_pretrained('pyannote/speaker-diarization-3.1', use_auth_token=hf_token)
    print('Successfully downloaded diarization model')
except Exception as e:
    print(f'Error downloading diarization model: {e}', file=sys.stderr)
    sys.exit(1)