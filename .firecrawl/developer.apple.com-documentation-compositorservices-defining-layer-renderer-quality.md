* * *

* * *

[Skip Navigation](https://developer.apple.com/documentation/compositorservices/defining-layer-renderer-quality#app-main)

- [Compositor Services](https://developer.apple.com/documentation/compositorservices)
- [LayerRenderer](https://developer.apple.com/documentation/compositorservices/layerrenderer)
- Defining layer renderer quality

Article

# Defining layer renderer quality

Declare the render quality of your textures to enable high-quality rendering.

## [Overview](https://developer.apple.com/documentation/compositorservices/defining-layer-renderer-quality\#Overview)

When rendering with Metal in visionOS, you need to define the render quality that best fits your app’s content. Text and other UI elements require less graphics power and benefit from higher resolution. Complex 3D scenes that require more graphic power can benefit from rendering at a lower resolution with more compute power available for every pixel. This API allows you to dynamically change the quality based on what your application is rendering.

### [Identify the default render quality](https://developer.apple.com/documentation/compositorservices/defining-layer-renderer-quality\#Identify-the-default-render-quality)

The [`defaultRenderQuality`](https://developer.apple.com/documentation/compositorservices/layerrenderer/capabilities/defaultrenderquality) property provides the default render quality. This value can vary on a system-by-system basis making it important to query the specific system value rather than expecting a constant value. Use the default render quality in your calculation of the maximum and preferred render quality when adopting higher-fidelity textures.

```
// Layer capabilities.
struct MyConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        let defaultQuality = capabilities.defaultRenderQuality

        // Configure other aspects of LayerRenderer.
    }
}
```

### [Set the maximum render quality](https://developer.apple.com/documentation/compositorservices/defining-layer-renderer-quality\#Set-the-maximum-render-quality)

Set a maximum render quality for your app as the first step in adopting higher-fidelity textures. This sets the upper limit for your rendering assertion. Adjust the quality of your displayed content within the range you set. Set the [`maxRenderQuality`](https://developer.apple.com/documentation/compositorservices/layerrenderer/configuration-swift.struct/maxrenderquality) to the minium value for your content to avoid overusing computation resources.

The following code sample sets a maximum render quality of `0.8` in the [`LayerRenderer.Configuration`](https://developer.apple.com/documentation/compositorservices/layerrenderer/configuration-swift.struct). Modifying the render quality only makes sense in the presence of foveation, so the sample performs a check for [`isFoveationEnabled`](https://developer.apple.com/documentation/compositorservices/layerrenderer/configuration-swift.struct/isfoveationenabled) first.

```
// Layer configuration.
struct MyConfiguration: CompositorLayerConfiguration {
    func makeConfiguration(capabilities: LayerRenderer.Capabilities,
                           configuration: inout LayerRenderer.Configuration) {
        // Configure other aspects of LayerRenderer.

        if configuration.isFoveationEnabled {
            configuration.maxRenderQuality = LayerRenderer.RenderQuality(0.8)
        }
    }
}
```

### [Set the desired render quality for a scene](https://developer.apple.com/documentation/compositorservices/defining-layer-renderer-quality\#Set-the-desired-render-quality-for-a-scene)

Similarly, you can set the desired render quality with the [`renderQuality`](https://developer.apple.com/documentation/compositorservices/layerrenderer/renderquality-swift.property) property. When loading a scene, set the desired render quality appropriate for that scene. The final visual product doesn’t immediately reflect the updated render quality. The system smooths the transition to the desired quality.

```
extension Renderer {
    func adjustRenderQuality(for scene: MyScene) {
        guard layerRenderer.configuration.isFoveationEnabled else {
            return
        }
        layerRenderer.renderQuality = scene.renderQuality
    }
}
```

For more information, see WWDC25 session 294 [What’s new in Metal rendering for immersive apps](https://developer.apple.com/videos/play/wwdc2025/294).

## [See Also](https://developer.apple.com/documentation/compositorservices/defining-layer-renderer-quality\#see-also)

### [Defining quality level](https://developer.apple.com/documentation/compositorservices/defining-layer-renderer-quality\#Defining-quality-level)

[`var renderQuality: LayerRenderer.RenderQuality`](https://developer.apple.com/documentation/compositorservices/layerrenderer/renderquality-swift.property)

Get the render quality to be used by the drawables.

[`var defaultRenderQuality: LayerRenderer.RenderQuality`](https://developer.apple.com/documentation/compositorservices/layerrenderer/capabilities/defaultrenderquality)

The default render quality used on this platform.

[`var maxRenderQuality: LayerRenderer.RenderQuality`](https://developer.apple.com/documentation/compositorservices/layerrenderer/configuration-swift.struct/maxrenderquality)

The max render quality the layer can use when drawing to the drawables.

Current page is Defining layer renderer quality