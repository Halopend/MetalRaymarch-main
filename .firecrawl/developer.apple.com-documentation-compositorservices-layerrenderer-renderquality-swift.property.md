* * *

* * *

[Skip Navigation](https://developer.apple.com/documentation/compositorservices/layerrenderer/renderquality-swift.property#app-main)

- [Compositor Services](https://developer.apple.com/documentation/compositorservices)
- [LayerRenderer](https://developer.apple.com/documentation/compositorservices/layerrenderer)
- renderQuality

Instance Property

# renderQuality

Get the render quality to be used by the drawables.

macOS 26.0+visionOS 26.0+

```
var renderQuality: LayerRenderer.RenderQuality { get set }
```

## [Mentioned in](https://developer.apple.com/documentation/compositorservices/layerrenderer/renderquality-swift.property\#mentions)

[Defining layer renderer quality](https://developer.apple.com/documentation/compositorservices/defining-layer-renderer-quality)

## [Discussion](https://developer.apple.com/documentation/compositorservices/layerrenderer/renderquality-swift.property\#discussion)

The render quality will increase the resolution at which rendering happens. This value cannot exceed the quality specified on the layer renderer configuration see [`cp_layer_renderer_configuration_set_max_render_quality`](https://developer.apple.com/documentation/compositorservices/cp_layer_renderer_configuration_set_max_render_quality). The quality will be changed to the target render quality over a set duration to hide the transition of quality from the user.

The renderer should monitor its frame rate to determine whether its making the frames on time. If it is unable to maintain proper frame rate, the app should reduce the render quality, reduce the scene complexity, or increase the frame repeat count see [`cp_layer_renderer_set_minimum_frame_repeat_count`](https://developer.apple.com/documentation/compositorservices/cp_layer_renderer_set_minimum_frame_repeat_count). It is generally preferable to reduce anything else before increasing the frame repeat count.

## [See Also](https://developer.apple.com/documentation/compositorservices/layerrenderer/renderquality-swift.property\#see-also)

### [Defining quality level](https://developer.apple.com/documentation/compositorservices/layerrenderer/renderquality-swift.property\#Defining-quality-level)

[`var defaultRenderQuality: LayerRenderer.RenderQuality`](https://developer.apple.com/documentation/compositorservices/layerrenderer/capabilities/defaultrenderquality)

The default render quality used on this platform.

[`var maxRenderQuality: LayerRenderer.RenderQuality`](https://developer.apple.com/documentation/compositorservices/layerrenderer/configuration-swift.struct/maxrenderquality)

The max render quality the layer can use when drawing to the drawables.

[Defining layer renderer quality](https://developer.apple.com/documentation/compositorservices/defining-layer-renderer-quality)

Declare the render quality of your textures to enable high-quality rendering.

Current page is renderQuality