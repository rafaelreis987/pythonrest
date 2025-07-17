import os
from langchain_openai import ChatOpenAI # Correct import for ChatOpenAI
import logging

logger = logging.getLogger(__name__)

# Lazy initialization - don't initialize at module import time
_openai_model = None
_initialization_error = None

def get_openai_model():
    """
    Lazy initialization of the OpenAI model.
    This ensures environment variables are properly set before initialization.
    """
    global _openai_model, _initialization_error
    
    if _openai_model is not None:
        return _openai_model
    
    if _initialization_error is not None:
        raise _initialization_error
    
    openai_api_key = os.getenv("OPENAI_API_KEY", "OPENAI_API_KEY_PLACEHOLDER")
    openai_model_name = os.getenv("OPENAI_MODEL", "gpt-3.5-turbo")
    openai_temperature = float(os.getenv("OPENAI_TEMPERATURE", "0.2"))
    openai_max_output_tokens = int(os.getenv("OPENAI_MAX_OUTPUT_TOKENS", "2000"))

    if openai_api_key and openai_api_key != "OPENAI_API_KEY_PLACEHOLDER":
        try:
            _openai_model = ChatOpenAI(
                model_name=openai_model_name, # ChatOpenAI uses model_name
                temperature=openai_temperature,
                max_tokens=openai_max_output_tokens, # ChatOpenAI uses max_tokens
                api_key=openai_api_key # Parameter name is api_key
            )
            logger.info(f"OpenAI model '{openai_model_name}' initialized successfully.")
            return _openai_model
        except Exception as e:
            logger.error(f"Failed to initialize OpenAI model '{openai_model_name}': {e}", exc_info=True)
            _initialization_error = e
            raise e
    else:
        error_msg = "OpenAI API Key is not configured or is a placeholder. Model not initialized."
        logger.warning(error_msg)
        _initialization_error = ValueError(error_msg)
        raise _initialization_error
