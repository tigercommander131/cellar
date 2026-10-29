/* Renders 180 frames with Direct3D 11 or 12 and reports which DLLs did the work.
 * Used to check Cellar's graphics backends without a game:  wine d3dtest.exe 11|12
 * Build: x86_64-w64-mingw32-gcc -O2 -o d3dtest.exe d3dtest.c -ld3d11 -ldxgi -luuid -mwindows */
#define COBJMACROS
#define WIDL_C_INLINE_WRAPPERS
#define INITGUID
#include <windows.h>
#include <stdio.h>
#include <d3d11.h>
#include <d3d12.h>
#include <dxgi1_4.h>

static FILE *out;

static void report_module(const char *name)
{
    char path[MAX_PATH] = "(not loaded)";
    HMODULE m = GetModuleHandleA(name);
    if (m) GetModuleFileNameA(m, path, sizeof(path));
    fprintf(out, "module %s: %s\n", name, path);
}

static LRESULT CALLBACK wndproc(HWND h, UINT msg, WPARAM w, LPARAM l)
{
    return DefWindowProcA(h, msg, w, l);
}

static HWND make_window(void)
{
    WNDCLASSA wc = {0};
    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "d3dtest";
    RegisterClassA(&wc);
    HWND h = CreateWindowA("d3dtest", "Cellar D3D test", WS_OVERLAPPEDWINDOW | WS_VISIBLE, 100, 100, 640, 360, NULL, NULL, wc.hInstance, NULL);
    return h;
}

static void pump(void)
{
    MSG msg;
    while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
}

static int test11(HWND hwnd)
{
    DXGI_SWAP_CHAIN_DESC sd = {0};
    ID3D11Device *dev; ID3D11DeviceContext *ctx; IDXGISwapChain *sc;
    ID3D11Texture2D *bb; ID3D11RenderTargetView *rtv;
    IDXGIDevice *dxgidev; IDXGIAdapter *adapter; DXGI_ADAPTER_DESC ad;
    D3D_FEATURE_LEVEL fl;
    sd.BufferCount = 2; sd.BufferDesc.Width = 640; sd.BufferDesc.Height = 360;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM; sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd; sd.SampleDesc.Count = 1; sd.Windowed = TRUE; sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0, D3D11_SDK_VERSION, &sd, &sc, &dev, &fl, &ctx);
    if (FAILED(hr)) { fprintf(out, "FAIL D3D11CreateDeviceAndSwapChain 0x%08lx\n", hr); return 1; }
    if (SUCCEEDED(ID3D11Device_QueryInterface(dev, &IID_IDXGIDevice, (void **)&dxgidev)) &&
        SUCCEEDED(IDXGIDevice_GetAdapter(dxgidev, &adapter)) && SUCCEEDED(IDXGIAdapter_GetDesc(adapter, &ad)))
        fprintf(out, "adapter: %ls (feature level 0x%x)\n", ad.Description, fl);
    IDXGISwapChain_GetBuffer(sc, 0, &IID_ID3D11Texture2D, (void **)&bb);
    ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)bb, NULL, &rtv);
    for (int i = 0; i < 180; i++) {
        float c[4] = {0.55f, 0.1f + (i % 60) / 120.0f, 0.2f, 1};
        ID3D11DeviceContext_OMSetRenderTargets(ctx, 1, &rtv, NULL);
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, c);
        hr = IDXGISwapChain_Present(sc, 1, 0);
        if (FAILED(hr)) { fprintf(out, "FAIL Present 0x%08lx at frame %d\n", hr, i); return 1; }
        pump();
    }
    fprintf(out, "OK d3d11 presented 180 frames\n");
    return 0;
}

static int test12(HWND hwnd)
{
    IDXGIFactory4 *factory; ID3D12Device *dev; ID3D12CommandQueue *queue; IDXGISwapChain1 *sc1;
    D3D12_COMMAND_QUEUE_DESC qd = {0};
    DXGI_SWAP_CHAIN_DESC1 sd = {0};
    LUID luid;
    HRESULT hr = CreateDXGIFactory2(0, &IID_IDXGIFactory4, (void **)&factory);
    if (FAILED(hr)) { fprintf(out, "FAIL CreateDXGIFactory2 0x%08lx\n", hr); return 1; }
    /* Loaded at run time so the D3D11 test also works where D3D12 is disabled (DXMT). */
    HMODULE d3d12 = LoadLibraryA("d3d12.dll");
    PFN_D3D12_CREATE_DEVICE create = d3d12 ? (PFN_D3D12_CREATE_DEVICE)GetProcAddress(d3d12, "D3D12CreateDevice") : NULL;
    if (!create) { fprintf(out, "FAIL d3d12.dll not available\n"); return 1; }
    hr = create(NULL, D3D_FEATURE_LEVEL_11_0, &IID_ID3D12Device, (void **)&dev);
    if (FAILED(hr)) { fprintf(out, "FAIL D3D12CreateDevice 0x%08lx\n", hr); return 1; }
    luid = ID3D12Device_GetAdapterLuid(dev);
    fprintf(out, "d3d12 device created (adapter LUID %08lx:%08lx)\n", luid.HighPart, luid.LowPart);
    qd.Type = D3D12_COMMAND_LIST_TYPE_DIRECT;
    hr = ID3D12Device_CreateCommandQueue(dev, &qd, &IID_ID3D12CommandQueue, (void **)&queue);
    if (FAILED(hr)) { fprintf(out, "FAIL CreateCommandQueue 0x%08lx\n", hr); return 1; }
    sd.Width = 640; sd.Height = 360; sd.Format = DXGI_FORMAT_R8G8B8A8_UNORM; sd.SampleDesc.Count = 1;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT; sd.BufferCount = 2; sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    hr = IDXGIFactory4_CreateSwapChainForHwnd(factory, (IUnknown *)queue, hwnd, &sd, NULL, NULL, &sc1);
    if (FAILED(hr)) { fprintf(out, "FAIL CreateSwapChainForHwnd 0x%08lx\n", hr); return 1; }
    for (int i = 0; i < 180; i++) {
        hr = IDXGISwapChain1_Present(sc1, 1, 0);
        if (FAILED(hr)) { fprintf(out, "FAIL Present 0x%08lx at frame %d\n", hr, i); return 1; }
        pump();
    }
    fprintf(out, "OK d3d12 presented 180 frames\n");
    return 0;
}

int WINAPI WinMain(HINSTANCE inst, HINSTANCE prev, LPSTR cmd, int show)
{
    char path[MAX_PATH];
    int ret;
    GetModuleFileNameA(NULL, path, sizeof(path));
    strcpy(strrchr(path, '\\') + 1, "d3dtest.log");
    out = fopen(path, "w");
    HWND hwnd = make_window();
    pump();
    ret = (cmd && strstr(cmd, "12")) ? test12(hwnd) : test11(hwnd);
    report_module("d3d11.dll");
    report_module("d3d12.dll");
    report_module("dxgi.dll");
    report_module("winemetal.dll");
    fclose(out);
    return ret;
}
