import os
from langchain_anthropic import ChatAnthropic # Correct import for ChatAnthropic
import logging

logger = logging.getLogger(__name__)

# Lazy initialization - don't initialize at module import time
_anthropic_model = None
_initialization_error = None

def get_anthropic_model():
    """
    Lazy initialization of the Anthropic model.
    This ensures environment variables are properly set before initialization.
    """
    global _anthropic_model, _initialization_error
    
    if _anthropic_model is not None:
        return _anthropic_model
    
    if _initialization_error is not None:
        raise _initialization_error
    
    anthropic_api_key = os.getenv("ANTHROPIC_API_KEY", "ANTHROPIC_API_KEY_PLACEHOLDER")
    anthropic_model_name = os.getenv("ANTHROPIC_MODEL", "claude-3-haiku-20240307")
    anthropic_temperature = float(os.getenv("ANTHROPIC_TEMPERATURE", "0.7"))
    anthropic_max_output_tokens = int(os.getenv("ANTHROPIC_MAX_OUTPUT_TOKENS", "2048"))

    if anthropic_api_key and anthropic_api_key != "ANTHROPIC_API_KEY_PLACEHOLDER":
        try:
            _anthropic_model = ChatAnthropic(
                model=anthropic_model_name, # ChatAnthropic uses model or model_name
                temperature=anthropic_temperature,
                max_tokens_to_sample=anthropic_max_output_tokens, # Older SDK versions used this. Newer might use max_tokens.
                api_key=anthropic_api_key # Parameter name is api_key
            )
            logger.info(f"Anthropic model '{anthropic_model_name}' initialized successfully.")
            return _anthropic_model
        except Exception as e:
            logger.error(f"Failed to initialize Anthropic model '{anthropic_model_name}': {e}", exc_info=True)
            if "max_tokens_to_sample" in str(e).lower() or "max_tokens" in str(e).lower():
                logger.error("This Anthropic error might be related to the 'max_tokens_to_sample' vs 'max_tokens' parameter. Check your langchain_anthropic SDK version.")
            _initialization_error = e
            raise e
    else:
        error_msg = "Anthropic API Key is not configured or is a placeholder. Model not initialized."
        logger.warning(error_msg)
        _initialization_error = ValueError(error_msg)
        raise _initialization_error
