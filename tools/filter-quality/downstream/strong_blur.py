"""Apply a size-relative blur to blocked outputs; classifications stay unchanged."""
import io,math
from PIL import Image,ImageFilter
class StrongBlurPipeline:
    def __init__(self,inner,configured_radius=32.0):
        self.inner=inner;self.configured_radius=float(configured_radius)
    def __getattr__(self,name):return getattr(self.inner,name)
    def filter_bytes(self,content,mime_type,source_url=None):
        outcome=self.inner.filter_bytes(content,mime_type,source_url)
        if outcome.decision.action.value!="blur"or outcome.replacement_bytes is None:return outcome
        with Image.open(io.BytesIO(outcome.replacement_bytes))as decoded:
            image=decoded.convert("RGB")
        target=max(self.configured_radius,min(image.size)*0.25)
        if target<=self.configured_radius:return outcome
        extra=math.sqrt(max(0,target*target-self.configured_radius*self.configured_radius))
        output=io.BytesIO()
        image.filter(ImageFilter.GaussianBlur(radius=extra)).save(output,format="PNG")
        outcome.replacement_bytes=output.getvalue()
        outcome.replacement_mime_type="image/png"
        details=outcome.response.get("pipeline",{}).get("modules",{}).get("imageRewrite",{}).get("details",{})
        details.update(outputMimeType="image/png",outputBytes=len(outcome.replacement_bytes),blurRadiusPixels=target,presentationRevision="size-relative-v1")
        return outcome
