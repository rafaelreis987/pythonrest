import os
from langchain_google_genai import ChatGoogleGenerativeAI
# Imports from the centralized EnvironmentVariables module
import logging

logger = logging.getLogger(__name__)

# Lazy initialization - don't initialize at module import time
_google_ai_model = None
_initialization_error = None

def get_google_ai_model():
    """
    Lazy initialization of the Google AI model.
    This ensures environment variables are properly set before initialization.
    """
    global _google_ai_model, _initialization_error
    
    if _google_ai_model is not None:
        return _google_ai_model
    
    if _initialization_error is not None:
        raise _initialization_error
    
    # Check if API key is a placeholder or empty, and only initialize if valid
    gemini_api_key = os.getenv("GEMINI_API_KEY", "GEMINI_API_KEY_PLACEHOLDER")
    gemini_model = os.getenv("GEMINI_MODEL", "gemini-1.5-flash")
    gemini_temperature = float(os.getenv("GEMINI_TEMPERATURE", "0.4"))
    gemini_max_output_tokens = int(os.getenv("GEMINI_MAX_OUTPUT_TOKENS", "2048"))

    # Log the API key status for debugging (without exposing the actual key)
    if gemini_api_key and gemini_api_key != "GEMINI_API_KEY_PLACEHOLDER":
        logger.info(f"Gemini API key is configured (length: {len(gemini_api_key)})")
    else:
        logger.warning(f"Gemini API key is not configured or is placeholder: {gemini_api_key}")

    if gemini_api_key and gemini_api_key != "GEMINI_API_KEY_PLACEHOLDER":
        try:
            _google_ai_model = ChatGoogleGenerativeAI(
                model=gemini_model,
                temperature=gemini_temperature,
                # The ChatGoogleGenerativeAI class uses 'max_output_tokens'
                max_output_tokens=gemini_max_output_tokens,
                google_api_key=gemini_api_key, # Parameter name is google_api_key
                # convert_system_message_to_human=True # May be needed depending on ReAct agent behavior with system messages
            )
            logger.info(f"GoogleAI (Gemini) model '{gemini_model}' initialized successfully.")
            return _google_ai_model
        except Exception as e:
            logger.error(f"Failed to initialize GoogleAI (Gemini) model '{gemini_model}': {e}", exc_info=True)
            _initialization_error = e
            raise e
    else:
        error_msg = "GoogleAI (Gemini) API Key is not configured or is a placeholder. Model not initialized."
        logger.warning(error_msg)
        _initialization_error = ValueError(error_msg)
        raise _initialization_error
